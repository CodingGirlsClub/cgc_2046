defmodule Cgc2046.Accounts.PortfolioItem do
  @moduledoc """
  用户作品集条目资源（P1-4 G9）。

  领域模型：
  - PortfolioItem 属于全局 User（user_id，非租户隔离——作品集是用户个人内容，
    不属于任何 Workspace）
  - 字段：title（必填）/ description（可空）/ url（可空）/ icon（document|book|guide）
  - 前端契约：profile 页 / portfolio 页展示作品集条目

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
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key(:id)

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
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:title, :description, :url, :icon])

      # user_id 自动填 actor，GraphQL 不暴露 user_id 参数（防伪造）。
      # 用 before_action：普通 change 在 for_create 构建阶段 actor 为 nil
      # 且 Ash.create(changeset) 不重跑普通 change；before_action 在
      # authorization 通过后执行，真实 actor 在 changeset.context[:private][:actor]
      # （回调闭包捕获的 context 是构建阶段的，actor 为 nil）。
      change(
        before_action(fn changeset, _context ->
          actor = changeset.context[:private][:actor]
          Ash.Changeset.force_change_attribute(changeset, :user_id, actor.id)
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

    # 当前用户自己的作品集（GraphQL myPortfolio）
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

  graphql do
    type(:portfolio_item)

    queries do
      list(:my_portfolio, :my_portfolio,
        type_name: :portfolio_item,
        description: "当前用户的作品集条目列表"
      )
    end

    mutations do
      create(:create_portfolio_item, :create, description: "创建作品集条目（user_id 自动为当前用户）")

      update(:update_portfolio_item, :update, description: "更新自己的作品集条目")

      destroy(:delete_portfolio_item, :destroy, description: "删除自己的作品集条目")
    end
  end
end
