defmodule Cgc2046.Accounts.Workspace do
  @moduledoc """
  全局工作台资源。

  领域模型（docs/01-定稿设计/领域模型定稿.md ER §5.2）：
  - `slug`：全局唯一、用户可读标识（创建者提供，格式 `^[a-z0-9-]+$`）
  - `join_policy`：加入策略三态 `open`（公开直接加入）/ `request`（公开申请审批）/ `invite_only`（私密仅邀请），默认 `request`
  - `sponsorship_enabled`：是否开放赞助入口，默认开

  权限（#62 范围，Leader 已拍板）：
  - 创建：仅平台管理员（`User.is_platform_admin == true`）
  - 读取：任何已认证用户可按 slug/id 定向查询（v1 不做公开 list，invite_only 不可被发现）
  - 更新：平台管理员可改；Owner 权限在 #64 引入 WorkspaceMembership 后收紧
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key(:id)

    attribute(:slug, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "工作台唯一标识（小写字母/数字/连字符，创建者提供）"
    )

    attribute(:name, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "工作台名称"
    )

    attribute(:join_policy, :atom,
      allow_nil?: false,
      default: :request,
      public?: true,
      writable?: true,
      constraints: [one_of: [:open, :request, :invite_only]],
      description: "加入策略：open 公开直接加入 / request 公开申请审批 / invite_only 私密仅邀请"
    )

    attribute(:sponsorship_enabled, :boolean,
      allow_nil?: false,
      default: true,
      public?: true,
      writable?: true,
      description: "是否开放赞助入口（默认开）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  validations do
    validate(match(:slug, ~r/^[a-z0-9-]+$/),
      message: "slug must only contain lowercase letters, numbers and hyphens"
    )
  end

  actions do
    default_accept(:*)
    defaults([:read, :create, :update])

    read :get_by_slug do
      description("按 slug 获取工作台")
      get_by([:slug])
    end

    read :get_by_id do
      description("按 id 获取工作台")
      get_by([:id])
    end
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  postgres do
    table("workspaces")
    repo(Cgc2046.Repo)
  end

  policies do
    policy action_type(:create) do
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end

    policy action_type(:update) do
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end

    policy action_type(:read) do
      authorize_if(actor_present())
    end
  end

  graphql do
    type(:workspace)

    queries do
      read_one(:get_workspace, :get_by_slug, description: "按 slug 获取工作台（需登录）")

      read_one(:get_workspace_by_id, :get_by_id, description: "按 id 获取工作台（需登录）")
    end

    mutations do
      create(:create_workspace, :create, description: "创建工作台（仅平台管理员）")

      update(:update_workspace, :update, description: "更新工作台（平台管理员）")
    end
  end
end
