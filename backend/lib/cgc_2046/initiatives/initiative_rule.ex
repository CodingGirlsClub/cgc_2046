defmodule Cgc2046.Initiatives.InitiativeRule do
  @moduledoc """
  Initiative 四项封闭规则；每项由 value + locked 表达。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Initiatives

  @keys [:deposit, :age_gate, :min_participants, :deadline_rule]

  attributes do
    uuid_primary_key(:id)
    attribute(:initiative_id, :uuid, allow_nil?: false, public?: true, writable?: true)

    attribute(:key, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: @keys]
    )

    attribute(:value, :map, allow_nil?: false, default: %{}, public?: true, writable?: true)

    attribute(:locked, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: true
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:initiative, Cgc2046.Initiatives.Initiative,
      source_attribute: :initiative_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  actions do
    defaults([:read])

    create :create do
      accept([:initiative_id, :key, :value, :locked])

      # 唯一索引冲突转稳定业务错误（#611，范式同 Initiative.handle_write_error/2）
      error_handler({__MODULE__, :handle_write_error, []})

      change(fn cs, _ ->
        Ash.Changeset.before_action(
          cs,
          &Cgc2046.Initiatives.RuleInheritance.prepare_rule_change/1
        )
      end)

      change({
        Cgc2046.Accounts.Changes.LogAdminAction,
        action: :initiative_rule_update,
        target_type: :initiative,
        target_id: &__MODULE__.rule_initiative_id/2,
        metadata: &Cgc2046.Accounts.Changes.LogAdminAction.initiative_rule_metadata/2
      })

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, rule ->
          case Cgc2046.Initiatives.RuleInheritance.propagate_rule_change(
                 rule.initiative_id,
                 rule.key,
                 rule.value,
                 rule.locked
               ) do
            :ok -> {:ok, rule}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)
    end

    update :update do
      require_atomic?(false)
      accept([:value, :locked])

      change(fn cs, _ ->
        Ash.Changeset.before_action(
          cs,
          &Cgc2046.Initiatives.RuleInheritance.prepare_rule_change/1
        )
      end)

      change({
        Cgc2046.Accounts.Changes.LogAdminAction,
        action: :initiative_rule_update,
        target_type: :initiative,
        target_id: &__MODULE__.rule_initiative_id/2,
        metadata: &Cgc2046.Accounts.Changes.LogAdminAction.initiative_rule_metadata/2
      })

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, rule ->
          case Cgc2046.Initiatives.RuleInheritance.propagate_rule_change(
                 rule.initiative_id,
                 rule.key,
                 rule.value,
                 rule.locked
               ) do
            :ok -> {:ok, rule}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)
    end
  end

  identities do
    identity(:unique_initiative_key, [:initiative_id, :key])
  end

  # create error_handler（#611）：同一 initiative 同一 key 撞
  # `initiative_rules_unique_initiative_key_index` → `initiative_rule_already_exists`。
  # 可达面 = AshAdmin 直接 create（GraphQL `upsertInitiativeRule` / MCP
  # `admin_upsert_initiative_rule` 都是读-后-写，只在并发窗口撞）。
  #
  # 按**约束名**分派而非"任意 unique 冲突"（范式：Event.handle_write_error/2 的五条
  # CHECK、enrollment 的核销码索引）：本表日后若加 identity，泛化判据会把新冲突
  # 误归因成既有业务码。非 unique 冲突（DB 断连等真故障）原样上抛，fail-closed。
  @doc false
  def handle_write_error(_changeset, error) do
    if Cgc2046.Errors.ConstraintConflict.unique_conflict?(error) and
         Cgc2046.Errors.ConstraintConflict.constraint_named?(
           error,
           "initiative_rules_unique_initiative_key_index"
         ) do
      Cgc2046.Errors.BusinessError.exception(
        message: "a rule for this initiative and key already exists",
        code: "initiative_rule_already_exists",
        fields: [:key]
      )
    else
      error
    end
  end

  postgres do
    table("initiative_rules")
    repo(Cgc2046.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  def rule_keys, do: @keys

  def rule_initiative_id(_changeset, rule), do: rule.initiative_id
end
