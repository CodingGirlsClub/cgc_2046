defmodule Cgc2046.Admission.InviteBatch do
  @moduledoc """
  Event/Course 的共享报名批次码。`remaining_quota` 仅由 Enrollment 创建事务中的
  条件 UPDATE 扣减；quota=1 自然形成一次性码。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Admission

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    attribute(:event_id, :uuid, public?: true, writable?: true)
    attribute(:course_id, :uuid, public?: true, writable?: true)

    attribute(:invite_code, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [match: ~r/^[A-Za-z0-9_-]{1,64}$/]
    )

    attribute(:quota, :integer,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [min: 1]
    )

    attribute(:remaining_quota, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 0]
    )

    attribute(:expires_at, :utc_datetime, public?: true, writable?: true)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :active,
      public?: true,
      writable?: true,
      constraints: [one_of: [:active, :disabled]]
    )

    attribute(:remark, :string, public?: true, writable?: true)

    create_timestamp(:inserted_at, public?: true)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
    belongs_to(:event, Cgc2046.Events.Event, define_attribute?: false)
    belongs_to(:course, Cgc2046.Courses.Course, define_attribute?: false)
  end

  identities do
    identity(:unique_invite_code, [:invite_code])
  end

  actions do
    defaults([:read])

    create :create do
      accept([:event_id, :course_id, :invite_code, :quota, :expires_at, :status, :remark])

      change(fn changeset, _context ->
        event_id = Ash.Changeset.get_attribute(changeset, :event_id)
        course_id = Ash.Changeset.get_attribute(changeset, :course_id)
        quota = Ash.Changeset.get_attribute(changeset, :quota)

        changeset
        |> validate_target(event_id, course_id)
        |> derive_target_tenant(event_id, course_id)
        |> Ash.Changeset.force_change_attribute(:remaining_quota, quota)
      end)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &validate_target_tenant/1)
      end)
    end

    update :disable do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          Ash.Changeset.force_change_attribute(cs, :status, :disabled)
        end)
      end)
    end
  end

  postgres do
    table("invite_batches")
    repo(Cgc2046.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end

  graphql do
    type(:invite_batch)

    queries do
      list(:invite_batches, :read)
    end

    mutations do
      create(:create_invite_batch, :create)
      update(:disable_invite_batch, :disable)
    end
  end

  defp validate_target(changeset, event_id, course_id) do
    if (!!event_id && !course_id) || (!event_id && !!course_id) do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :event_id,
        message: "exactly one of event_id/course_id is required"
      )
    end
  end

  defp derive_target_tenant(changeset, event_id, course_id) do
    case target_workspace_id(event_id, course_id) do
      {:ok, target_workspace_id} ->
        tenant = changeset.tenant || target_workspace_id

        changeset
        |> Ash.Changeset.set_tenant(tenant)
        |> Ash.Changeset.force_change_attribute(:workspace_id, tenant)

      {:error, :not_found} ->
        Ash.Changeset.add_error(changeset,
          field: :event_id,
          message: "target does not belong to tenant"
        )

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset,
          field: :event_id,
          message: "target does not belong to tenant"
        )

      :skip ->
        changeset
    end
  end

  defp target_workspace_id(event_id, nil) when is_binary(event_id) do
    lookup_target_workspace("events", event_id)
  end

  defp target_workspace_id(nil, course_id) when is_binary(course_id) do
    lookup_target_workspace("courses", course_id)
  end

  defp target_workspace_id(_event_id, _course_id), do: :skip

  defp lookup_target_workspace(table, id) do
    case Cgc2046.Repo.query("SELECT workspace_id FROM #{table} WHERE id = $1", [
           Cgc2046.Repo.uuid!(id)
         ]) do
      {:ok, %{rows: [[workspace_id]]}} -> {:ok, Ecto.UUID.load!(workspace_id)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_target_tenant(changeset) do
    {table, id} =
      case {
        Ash.Changeset.get_attribute(changeset, :event_id),
        Ash.Changeset.get_attribute(changeset, :course_id)
      } do
        {event_id, nil} when is_binary(event_id) -> {"events", event_id}
        {nil, course_id} when is_binary(course_id) -> {"courses", course_id}
        _ -> {nil, nil}
      end

    if table && changeset.tenant do
      tenant_id = Cgc2046.Repo.uuid!(changeset.tenant)

      case Cgc2046.Repo.query("SELECT workspace_id FROM #{table} WHERE id = $1", [
             Cgc2046.Repo.uuid!(id)
           ]) do
        {:ok, %{rows: [[workspace_id]]}} when workspace_id == tenant_id ->
          changeset

        _ ->
          Ash.Changeset.add_error(changeset,
            field: :event_id,
            message: "target does not belong to tenant"
          )
      end
    else
      changeset
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:admission)
    label_field(:invite_code)

    table_columns([
      :id,
      :workspace_id,
      :invite_code,
      :quota,
      :remaining_quota,
      :status,
      :expires_at,
      :inserted_at
    ])
  end
end
