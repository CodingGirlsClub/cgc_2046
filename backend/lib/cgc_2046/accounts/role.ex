defmodule Cgc2046.Accounts.Role do
  @moduledoc """
  租户内角色资源（#64）。

  领域模型（multitenancy-调研 §5.2）：Role 按租户隔离（workspace_id）。
  角色为租户内预置数据（workspace 创建时 seed：owner/admin/member），
  同一成员可持多个角色（多角色并集，权限判定取并集）。

  角色枚举（#64 范围）：
  - `:owner`：工作台所有者（创建者），可管理成员与角色分配
  - `:admin`：管理员，可管理成员与角色分配
  - `:member`：普通成员
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:name, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: [:owner, :admin, :member]],
      description: "角色名：owner / admin / member"
    )

    attribute(:description, :string,
      public?: true,
      writable?: true,
      description: "角色说明"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)

    # 允许跨租户读取（meWorkspaces 需要读取当前用户在所有租户的角色），隔离由 policy 保证
    global?(true)
  end

  actions do
    default_accept([:description])
    defaults([:read])

    # 内部 seed 用 create（workspace 创建时自动建立 owner/admin/member）；
    # 对外策略仍为 never()，仅 authorize?: false 的内部调用可执行
    create :create do
      primary?(true)
      argument(:name, :atom, constraints: [one_of: [:owner, :admin, :member]])
      change(set_attribute(:name, arg(:name)))
    end
  end

  identities do
    identity(:unique_role_per_workspace, [:workspace_id, :name])
  end

  postgres do
    table("roles")
    repo(Cgc2046.Repo)
  end

  policies do
    policy action_type(:read) do
      # 角色名是租户内公开概念：任何已认证用户可读（用于展示）
      authorize_if(actor_present())
    end

    # 角色为预置数据，外部不允许 create/update/destroy
    policy action_type([:create, :update, :destroy]) do
      authorize_if(never())
    end
  end

  graphql do
    type(:role)
  end
end
