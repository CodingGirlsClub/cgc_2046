defmodule Cgc2046.Initiatives.Initiative do
  @moduledoc """
  平台级 Initiative；不属于任何 Workspace。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Initiatives

  @statuses [:draft, :open, :closed]

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:slug, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:hashtag, :string, public?: true, writable?: true)
    attribute(:description, :string, public?: true, writable?: true)
    attribute(:window_starts_at, :utc_datetime, public?: true, writable?: true)
    attribute(:window_ends_at, :utc_datetime, public?: true, writable?: true)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :draft,
      public?: true,
      writable?: false,
      constraints: [one_of: @statuses]
    )

    attribute(:created_by, :uuid, allow_nil?: false, public?: true, writable?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:creator, Cgc2046.Accounts.User,
      source_attribute: :created_by,
      destination_attribute: :id,
      define_attribute?: false
    )

    has_many(:rules, Cgc2046.Initiatives.InitiativeRule, destination_attribute: :initiative_id)
    has_many(:events, Cgc2046.Events.Event, destination_attribute: :initiative_id)
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :name,
        :slug,
        :hashtag,
        :description,
        :window_starts_at,
        :window_ends_at,
        :created_by
      ])

      change(set_attribute(:status, :draft))

      # 撞 slug 的唯一索引冲突（#604）转稳定业务错误 initiative_slug_taken
      error_handler({__MODULE__, :handle_write_error, []})

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :initiative_create, target_type: :initiative}
      )
    end

    update :update do
      require_atomic?(false)
      accept([:name, :slug, :hashtag, :description, :window_starts_at, :window_ends_at])

      # 撞 slug 的唯一索引冲突（#604）转稳定业务错误 initiative_slug_taken
      error_handler({__MODULE__, :handle_write_error, []})

      # 发布后 slug 锁定（#588；决策口径同 Event/Course 2026-09-08 拍板）：
      # 公开 URL 段发布即契约——#577 之后 `/initiatives/<slug>` 是正式投放出口
      # （web admin 复制公开链接 / MCP `url` 字段 / sitemap 动态条目），改名 ⇒
      # 已分发链接即刻 404、sitemap 收录页失效。draft 随便改；无 rename 后门
      # （终态语义同款：恢复路径 = 新建）。
      #
      # 与 Event/Course 的偏差（有意）：那边是裸 `add_error`，落 GraphQL 只有
      # `invalid_attribute`（不在 #241 契约、两端无文案）；本处用 BusinessError
      # 带稳定 code，因为 #588 验收要求「返回稳定 code（含 zh/en 文案）」。
      #
      # 同值回传不算变更：表单（web admin）在非 draft 态 disabled 但仍原样回传
      # 旧 slug，`Ash.Changeset.do_change_attribute` 在 `Ash.Type.equal?/3` 为真时
      # 会从 `attributes` 里删掉该键，而 `changing_attribute?/2` 只查
      # `Map.has_key?(attributes, key)`（ash 3.x `changeset.ex`）——故不会误触发。
      change(fn changeset, _context ->
        if Ash.Changeset.changing_attribute?(changeset, :slug) and
             Ash.Changeset.get_data(changeset, :status) != :draft do
          Ash.Changeset.add_error(
            changeset,
            Cgc2046.Errors.BusinessError.exception(
              message: "slug is locked once the initiative is published (editable in draft only)",
              code: "initiative_slug_locked",
              fields: [:slug]
            )
          )
        else
          changeset
        end
      end)

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :initiative_update, target_type: :initiative}
      )
    end

    update :open do
      require_atomic?(false)
      accept([])

      change(fn cs, _ -> Ash.Changeset.before_action(cs, &transition(&1, :draft, :open)) end)

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :initiative_open, target_type: :initiative}
      )
    end

    update :close do
      require_atomic?(false)
      accept([])
      change(fn cs, _ -> Ash.Changeset.before_action(cs, &transition(&1, :open, :closed)) end)

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :initiative_close, target_type: :initiative}
      )
    end
  end

  validations do
    # `only_when_valid?`（#588）：slug 锁定守卫是 action change，跑在全局
    # validation 之前（Ash `for_update` 流水线 run_action_changes → add_validations）。
    # 锁定时 changeset 已 invalid，本格式校验被跳过 ⇒ 非 draft 传「又非法又锁定」
    # 的 slug 只回一个错误 `initiative_slug_locked`，而不是叠加格式错让前端
    # firstError 显示「slug must be a single lowercase URL segment」——
    # 那会把人骗进「改好格式再来」的死循环（再来仍被锁）。
    # create 与 draft 改名路径行为不变（守卫不触发 ⇒ changeset 仍 valid）。
    validate(match(:slug, ~r/^[a-z0-9][a-z0-9-]*$/), only_when_valid?: true)
  end

  defp transition(changeset, from, to) do
    repo = Cgc2046.Repo

    with {:ok, %{rows: [[status]]}} <-
           repo.query("SELECT status FROM initiatives WHERE id = $1 FOR UPDATE", [
             repo.uuid!(changeset.data.id)
           ]),
         true <- status == to_string(from),
         true <- to != :open or Cgc2046.Initiatives.RuleInheritance.ready?(changeset.data.id) do
      Ash.Changeset.force_change_attribute(changeset, :status, to)
    else
      _ ->
        Ash.Changeset.add_error(
          changeset,
          "invalid initiative transition or missing all four rules"
        )
    end
  end

  # create/update error_handler（#604，范式同 Event.handle_write_error/2）：
  # 撞 slug 的唯一索引冲突转稳定业务错误 initiative_slug_taken。
  #
  # 判据是 ConstraintConflict.unique_conflict?/1（认 ash_postgres 写入的
  # private_vars.constraint_type == :unique）；DB 断连等真实故障不含该键，原样
  # 上抛，不吞成业务错误。这要求 DB 索引名与 identity 名一致——否则 Ecto 的
  # `unique_constraint(match: :exact)` 匹配不上，错误会落 Ash.Error.Unknown 且
  # 原文含索引名（修复见 migration 20260916130000）。
  #
  # initiatives 只有一个 identity（unique_slug），故按类型判定即可；日后新增
  # identity 须改按约束名分派（ConstraintConflict.constraint_named?/2，范式同
  # enrollment 的核销码冲突）。
  #
  # 「发布后锁定」（#588）是 action change 在写库前 add_error，走不到这里，
  # 故 slug 又锁又撞时仍只回 initiative_slug_locked（边界测试钉住优先级）。
  @doc false
  def handle_write_error(_changeset, error) do
    if Cgc2046.Errors.ConstraintConflict.unique_conflict?(error) do
      Cgc2046.Errors.BusinessError.exception(
        message: "slug has already been taken",
        code: "initiative_slug_taken",
        fields: [:slug]
      )
    else
      error
    end
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  postgres do
    table("initiatives")
    repo(Cgc2046.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:create) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:update) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end
