defmodule Cgc2046.Accounts.PortfolioItem do
  @moduledoc """
  用户作品集条目资源（P1-4 G9）。

  领域模型（ADR-0004）：
  - PortfolioItem 属于租户（workspace_id + user_id，multitenancy by workspace_id）——
    作品集是 Profile 的一部分，per-workspace 展示
  - 字段：title（必填）/ description（可空）/ url（可空）/ icon（document|book|guide）
  - 前端契约：profile 页 / portfolio 页展示作品集条目（按当前 workspace 取）

  授权（仅本人）：
  - create：自动填 user_id = actor.id（GraphQL mutation 不接受 user_id 参数，
    防止伪造他人作品集）
  - read / update / destroy：filter 阶段 `user_id == actor.id`，只能操作自己的条目

  GraphQL 契约：
  - query `myPortfolio` → [PortfolioItem!]!
  - mutation `createPortfolioItem(input: {title, description, url, icon})`
  - mutation `updatePortfolioItem(id, input: {title, description, url, icon})`
  - mutation `deletePortfolioItem(id)`
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID（ADR-0004：Portfolio 为租户资源）"
    )

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "作品集所属用户 ID（仅本人，创建时自动填充）"
    )

    attribute(:title, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "作品标题"
    )

    attribute(:description, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "作品描述"
    )

    attribute(:url, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "作品链接"
    )

    attribute(:icon, :atom,
      allow_nil?: false,
      default: :document,
      public?: true,
      writable?: true,
      constraints: [one_of: [:document, :book, :guide]],
      description: "作品图标类型（document/book/guide）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)

    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)

    # 允许跨租户读取（迁移回填等需要），隔离由 policy 保证
    global?(true)
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:title, :description, :url, :icon])

      # user_id 自动填 actor，workspace_id 自动填 tenant（multitenancy）；GraphQL 不暴露
      # user_id/workspace_id 参数（防伪造跨租户写入）。
      # 用 before_action：普通 change 在 for_create 构建阶段 actor 为 nil
      # 且 Ash.create(changeset) 不重跑普通 change；before_action 在
      # authorization 通过后执行，真实 actor 在 changeset.context[:private][:actor]
      # （回调闭包捕获的 context 是构建阶段的，actor 为 nil）。
      change(
        before_action(fn changeset, _context ->
          actor = changeset.context[:private][:actor]
          cs = Ash.Changeset.force_change_attribute(changeset, :user_id, actor.id)

          case changeset.tenant do
            nil ->
              cs

            workspace_id ->
              Ash.Changeset.force_change_attribute(cs, :workspace_id, workspace_id)
          end
        end)
      )
    end

    update :update do
      primary?(true)
      require_atomic?(false)
      accept([:title, :description, :url, :icon])
    end

    destroy :destroy do
      primary?(true)
    end

    # 当前用户在某 workspace 自己的作品集（GraphQL myWorkspacePortfolio）。
    # workspace_id 隔离由 multitenancy（tenant）自动应用，这里仅过滤本人。
    read :my_portfolio do
      filter(expr(user_id == ^actor(:id)))
    end
  end

  postgres do
    table("portfolio_items")
    repo(Cgc2046.Repo)
  end

  policies do
    # 匿名无 actor：一律拒绝（避免 nil == nil 让未设 user_id 的 changeset 通过）
    policy action_type([:create, :read, :update, :destroy]) do
      forbid_if(expr(is_nil(^actor(:id))))
      authorize_if(expr(user_id == ^actor(:id)))
    end
  end
end
