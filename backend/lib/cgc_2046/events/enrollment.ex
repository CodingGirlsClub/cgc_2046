defmodule Cgc2046.Events.Enrollment do
  @moduledoc """
  Event/Course 报名资源。

  核心并发不变量由数据库承担：目标活动的 `confirmed_count` 通过条件 UPDATE
  占位，InviteBatch 配额通过 `remaining_quota > 0` 条件 UPDATE 扣减，报名本身
  由两个部分唯一索引防重复。所有写都位于 Ash action 事务内，后续步骤失败会回滚
  已执行的计数更新。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  alias Cgc2046.Workflows.JidoAdapter

  @default_approval_timeout_days 7

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    attribute(:event_id, :uuid, public?: true, writable?: true)
    attribute(:course_id, :uuid, public?: true, writable?: true)

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true
    )

    attribute(:workflow_run_id, :uuid, public?: true, writable?: true)
    attribute(:invite_batch_id, :uuid, public?: true, writable?: false)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      writable?: false,
      constraints: [one_of: [:pending, :confirmed, :rejected, :expired, :cancelled]]
    )

    attribute(:submission_payload, :map,
      allow_nil?: false,
      default: %{},
      public?: true,
      writable?: true
    )

    attribute(:capacity_seq, :integer, public?: true, writable?: false)
    attribute(:approved_by, :uuid, public?: true, writable?: false)
    attribute(:approved_at, :utc_datetime, public?: true, writable?: false)
    attribute(:rejection_reason, :string, public?: true, writable?: false)
    attribute(:approval_deadline, :utc_datetime, public?: true, writable?: true)
    attribute(:expired_at, :utc_datetime, public?: true, writable?: false)
    attribute(:cancelled_at, :utc_datetime, public?: true, writable?: false)

    create_timestamp(:inserted_at)
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
    belongs_to(:course, Cgc2046.Events.Course, define_attribute?: false)
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
    belongs_to(:workflow_run, Cgc2046.Workflows.WorkflowRun, define_attribute?: false)
    belongs_to(:invite_batch, Cgc2046.Events.InviteBatch, define_attribute?: false)

    belongs_to(:approver, Cgc2046.Accounts.User,
      define_attribute?: false,
      source_attribute: :approved_by
    )
  end

  identities do
    identity :unique_event_user, [:event_id, :user_id] do
      where(expr(not is_nil(event_id) and status in [:pending, :confirmed]))
    end

    identity :unique_course_user, [:course_id, :user_id] do
      where(expr(not is_nil(course_id) and status in [:pending, :confirmed]))
    end
  end

  actions do
    defaults([:read])

    create :create_enrollment do
      description("创建报名；open/invite_only 立即占位，request 等待审批")

      accept([
        :event_id,
        :course_id,
        :user_id,
        :workflow_run_id,
        :submission_payload,
        :approval_deadline
      ])

      argument(:invite_code, :string, allow_nil?: true)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_create/1)
      end)
    end

    update :confirm_enrollment do
      description("Owner/Admin 确认 pending 报名并原子占用名额")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_confirm/1)
      end)

      change(
        after_transaction(fn changeset, result, _context ->
          publish_approval_signal(changeset, result, "enrollment.approved")
        end)
      )
    end

    update :reject_enrollment do
      description("Owner/Admin 拒绝 pending 报名")
      require_atomic?(false)
      accept([])
      argument(:rejection_reason, :string, allow_nil?: true)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_reject/1)
      end)

      change(
        after_transaction(fn changeset, result, _context ->
          publish_approval_signal(changeset, result, "enrollment.rejected")
        end)
      )
    end

    update :expire do
      description("内部扫描把过期 pending 报名转 expired")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_expire/1)
      end)
    end

    update :cancel do
      description("报名人取消报名；confirmed 报名释放名额")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_cancel/1)
      end)
    end
  end

  postgres do
    table("enrollments")
    repo(Cgc2046.Repo)

    identity_wheres_to_sql(
      unique_event_user: "event_id IS NOT NULL AND status IN ('pending', 'confirmed')",
      unique_course_user: "course_id IS NOT NULL AND status IN ('pending', 'confirmed')"
    )
  end

  policies do
    policy action(:create_enrollment) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action([:confirm_enrollment, :reject_enrollment]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end

    policy action(:cancel) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end
  end

  graphql do
    type(:enrollment)

    queries do
      list(:enrollments, :read)
    end

    mutations do
      create(:create_enrollment, :create_enrollment)
      update(:confirm_enrollment, :confirm_enrollment)
      update(:reject_enrollment, :reject_enrollment)
      update(:cancel_enrollment, :cancel)
    end
  end

  defp prepare_create(changeset) do
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)
    course_id = Ash.Changeset.get_attribute(changeset, :course_id)

    with {:ok, target_kind, target_id} <- exactly_one_target(event_id, course_id),
         {:ok, target} <- eligible_target(target_kind, target_id),
         :ok <- tenant_matches?(changeset.tenant, target.workspace_id),
         {:ok, attrs} <- prepare_policy(changeset, target_kind, target_id, target) do
      Enum.reduce(attrs, changeset, fn {key, value}, cs ->
        Ash.Changeset.force_change_attribute(cs, key, value)
      end)
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  defp prepare_policy(changeset, _kind, _target_id, %{enrollment_policy: :request}) do
    deadline =
      Ash.Changeset.get_attribute(changeset, :approval_deadline) ||
        DateTime.add(DateTime.utc_now(), @default_approval_timeout_days, :day)

    {:ok, %{workspace_id: changeset.tenant, status: :pending, approval_deadline: deadline}}
  end

  defp prepare_policy(changeset, kind, target_id, %{enrollment_policy: :open}) do
    with {:ok, sequence} <- reserve_capacity(kind, target_id) do
      {:ok, %{workspace_id: changeset.tenant, status: :confirmed, capacity_seq: sequence}}
    end
  end

  defp prepare_policy(changeset, kind, target_id, %{enrollment_policy: :invite_only}) do
    invite_code = Ash.Changeset.get_argument(changeset, :invite_code)

    with true <- (is_binary(invite_code) and invite_code != "") || {:error, :invite_code_required},
         {:ok, sequence} <- reserve_capacity(kind, target_id),
         {:ok, batch_id} <- consume_invite_quota(changeset.tenant, kind, target_id, invite_code) do
      {:ok,
       %{
         workspace_id: changeset.tenant,
         status: :confirmed,
         capacity_seq: sequence,
         invite_batch_id: batch_id
       }}
    end
  end

  defp prepare_confirm(changeset) do
    now = DateTime.utc_now()
    actor = changeset.context[:private][:actor]

    with {:ok, kind, target_id} <- target_from_record(changeset.data),
         {:ok, sequence} <- reserve_capacity(kind, target_id),
         {:ok, 1} <- claim_pending(changeset.data.id, :confirmed, actor.id, now, nil) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :confirmed)
      |> Ash.Changeset.force_change_attribute(:capacity_seq, sequence)
      |> Ash.Changeset.force_change_attribute(:approved_by, actor.id)
      |> Ash.Changeset.force_change_attribute(:approved_at, now)
    else
      {:ok, 0} -> add_domain_error(changeset, :already_processed)
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  defp prepare_reject(changeset) do
    now = DateTime.utc_now()
    actor = changeset.context[:private][:actor]
    reason = Ash.Changeset.get_argument(changeset, :rejection_reason)

    case claim_pending(changeset.data.id, :rejected, actor.id, now, reason) do
      {:ok, 1} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :rejected)
        |> Ash.Changeset.force_change_attribute(:approved_by, actor.id)
        |> Ash.Changeset.force_change_attribute(:approved_at, now)
        |> Ash.Changeset.force_change_attribute(:rejection_reason, reason)

      {:ok, 0} ->
        add_domain_error(changeset, :already_processed)

      {:error, reason} ->
        add_domain_error(changeset, reason)
    end
  end

  defp prepare_expire(changeset) do
    now = DateTime.utc_now()

    sql = """
    UPDATE enrollments
    SET status = 'expired', expired_at = $1
    WHERE id = $2 AND status = 'pending'
      AND approval_deadline IS NOT NULL AND approval_deadline < $1
    """

    case Cgc2046.Repo.query(sql, [now, uuid!(changeset.data.id)]) do
      {:ok, %{num_rows: 1}} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :expired)
        |> Ash.Changeset.force_change_attribute(:expired_at, now)

      {:ok, %{num_rows: 0}} ->
        add_domain_error(changeset, :not_expired_pending)

      {:error, reason} ->
        add_domain_error(changeset, {:database, reason})
    end
  end

  defp prepare_cancel(changeset) do
    now = DateTime.utc_now()

    with {:ok, capacity_target} <- claim_cancellable(changeset.data.id, now),
         :ok <- release_capacity(capacity_target) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :cancelled)
      |> Ash.Changeset.force_change_attribute(:cancelled_at, now)
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  defp exactly_one_target(event_id, nil) when is_binary(event_id), do: {:ok, :event, event_id}
  defp exactly_one_target(nil, course_id) when is_binary(course_id), do: {:ok, :course, course_id}
  defp exactly_one_target(_, _), do: {:error, :exactly_one_target_required}

  defp target_from_record(%{event_id: event_id, course_id: nil}) when is_binary(event_id),
    do: {:ok, :event, event_id}

  defp target_from_record(%{event_id: nil, course_id: course_id}) when is_binary(course_id),
    do: {:ok, :course, course_id}

  defp target_from_record(_), do: {:error, :exactly_one_target_required}

  defp eligible_target(kind, id) do
    table = target_table(kind)

    sql = """
    SELECT workspace_id, enrollment_policy
    FROM #{table}
    WHERE id = $1 AND status = 'open'
      AND (registration_deadline IS NULL OR registration_deadline > NOW())
    FOR SHARE
    """

    case Cgc2046.Repo.query(sql, [uuid!(id)]) do
      {:ok, %{rows: [[workspace_id, policy]]}} ->
        {:ok,
         %{
           workspace_id: Ecto.UUID.load!(workspace_id),
           enrollment_policy: String.to_existing_atom(policy)
         }}

      {:ok, %{rows: []}} ->
        {:error, :target_not_open_or_registration_closed}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp reserve_capacity(kind, id) do
    table = target_table(kind)

    sql = """
    UPDATE #{table}
    SET confirmed_count = confirmed_count + 1, updated_at = NOW()
    WHERE id = $1 AND status = 'open'
      AND (registration_deadline IS NULL OR registration_deadline > NOW())
      AND (capacity IS NULL OR confirmed_count < capacity)
    RETURNING confirmed_count
    """

    case Cgc2046.Repo.query(sql, [uuid!(id)]) do
      {:ok, %{rows: [[sequence]]}} -> {:ok, sequence}
      {:ok, %{rows: []}} -> {:error, :capacity_full_or_registration_closed}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp consume_invite_quota(workspace_id, kind, target_id, invite_code) do
    target_column = if kind == :event, do: "event_id", else: "course_id"

    sql = """
    UPDATE invite_batches
    SET remaining_quota = remaining_quota - 1, updated_at = NOW()
    WHERE workspace_id = $1 AND #{target_column} = $2 AND invite_code = $3
      AND status = 'active' AND remaining_quota > 0
      AND (expires_at IS NULL OR expires_at > NOW())
    RETURNING id
    """

    case Cgc2046.Repo.query(sql, [uuid!(workspace_id), uuid!(target_id), invite_code]) do
      {:ok, %{rows: [[id]]}} -> {:ok, Ecto.UUID.load!(id)}
      {:ok, %{rows: []}} -> {:error, :invite_quota_unavailable}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp claim_pending(id, status, actor_id, now, rejection_reason) do
    sql = """
    UPDATE enrollments
    SET status = $1, approved_by = $2, approved_at = $3, rejection_reason = $4
    WHERE id = $5 AND status = 'pending'
      AND (approval_deadline IS NULL OR approval_deadline > $3)
    """

    case Cgc2046.Repo.query(sql, [
           to_string(status),
           uuid!(actor_id),
           now,
           rejection_reason,
           uuid!(id)
         ]) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp claim_cancellable(id, now) do
    sql = """
    UPDATE enrollments
    SET status = 'cancelled', cancelled_at = $1
    WHERE id = $2 AND status IN ('pending', 'confirmed')
    RETURNING capacity_seq, event_id, course_id
    """

    case Cgc2046.Repo.query(sql, [now, uuid!(id)]) do
      {:ok, %{rows: [[nil, _event_id, _course_id]]}} ->
        {:ok, nil}

      {:ok, %{rows: [[_capacity_seq, event_id, nil]]}} when not is_nil(event_id) ->
        {:ok, {:event, Ecto.UUID.load!(event_id)}}

      {:ok, %{rows: [[_capacity_seq, nil, course_id]]}} when not is_nil(course_id) ->
        {:ok, {:course, Ecto.UUID.load!(course_id)}}

      {:ok, %{rows: []}} ->
        {:error, :already_processed}

      {:ok, _unexpected} ->
        {:error, :capacity_counter_invalid}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp release_capacity(nil), do: :ok

  defp release_capacity({kind, target_id}) do
    table = target_table(kind)

    case Cgc2046.Repo.query(
           "UPDATE #{table} SET confirmed_count = confirmed_count - 1 WHERE id = $1 AND confirmed_count > 0",
           [uuid!(target_id)]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :capacity_counter_invalid}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp tenant_matches?(tenant, workspace_id) when tenant == workspace_id, do: :ok
  defp tenant_matches?(_, _), do: {:error, :target_tenant_mismatch}

  defp target_table(:event), do: "events"
  defp target_table(:course), do: "courses"

  defp add_domain_error(changeset, reason) do
    Ash.Changeset.add_error(changeset,
      field: :status,
      message: domain_error_message(reason)
    )
  end

  defp domain_error_message(:exactly_one_target_required),
    do: "exactly one of event_id/course_id is required"

  defp domain_error_message(:target_not_open_or_registration_closed),
    do: "target is not open or registration deadline passed"

  defp domain_error_message(:target_tenant_mismatch), do: "target does not belong to tenant"
  defp domain_error_message(:capacity_full_or_registration_closed), do: "capacity is full"
  defp domain_error_message(:invite_code_required), do: "invite code is required"
  defp domain_error_message(:invite_quota_unavailable), do: "invite quota is unavailable"
  defp domain_error_message(:already_processed), do: "enrollment has already been processed"

  defp domain_error_message(:not_expired_pending),
    do: "enrollment is not an expired pending record"

  defp domain_error_message(:capacity_counter_invalid), do: "capacity counter is invalid"
  defp domain_error_message({:database, _reason}), do: "database operation failed"
  defp domain_error_message(reason), do: inspect(reason)

  defp publish_approval_signal(changeset, {:ok, enrollment} = result, signal_type) do
    payload = %{
      "enrollment_id" => enrollment.id,
      "workspace_id" => enrollment.workspace_id,
      "user_id" => enrollment.user_id,
      "status" => to_string(enrollment.status)
    }

    _ = JidoAdapter.publish(signal_type, payload, changeset.tenant)
    result
  end

  defp publish_approval_signal(_changeset, result, _signal_type), do: result

  defp uuid!(value), do: Ecto.UUID.dump!(value)
end
