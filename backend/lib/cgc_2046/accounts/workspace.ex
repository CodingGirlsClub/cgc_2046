defmodule Cgc2046.Accounts.Workspace do
  @moduledoc """
  全局工作台资源。

  领域模型（docs/01-定稿设计/领域模型定稿.md ER §5.2）：
  - `slug`：全局唯一、用户可读标识（创建者提供，格式 `^[a-z0-9-]+$`）
  - `join_policy`：加入策略三态 `open`（公开直接加入）/ `request`（公开申请审批）/ `invite_only`（私密仅邀请），默认 `request`
  - `sponsorship_enabled`：是否开放赞助入口，默认开

  权限（#62 + #64，Leader 已拍板）：
  - 创建：仅平台管理员；创建时自动 seed 角色（owner/admin/member）并建立 Owner 成员资格（#64）
  - 读取：open/request 工作台对已认证用户可定向查询；invite_only 仅成员/管理员/平台管理员可读（非成员返回 null/forbidden，不可发现）
  - 更新：平台管理员可改；Owner 权限在 #64 之后收紧为成员管理相关操作
  - `me_workspaces`：返回当前用户可进入（成员或创建者）的工作台列表，供前端 #63 使用
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

  calculations do
    calculate(
      :my_role_names,
      {:array, :string},
      {Cgc2046.Accounts.Calculations.CurrentMembershipInfo, key: :my_role_names},
      public?: true,
      description: "当前用户在该工作台的角色名数组（非成员为 []）"
    )

    calculate(
      :my_membership_id,
      :uuid,
      {Cgc2046.Accounts.Calculations.CurrentMembershipInfo, key: :my_membership_id},
      public?: true,
      description: "当前用户在该工作台的成员资格 ID（非成员为 null）"
    )

    calculate(
      :can_access,
      :boolean,
      {Cgc2046.Accounts.Calculations.CurrentMembershipInfo, key: :can_access},
      public?: true,
      description: "当前用户是否可进入该工作台（成员/创建者）"
    )
  end

  relationships do
    has_many(:memberships, Cgc2046.Accounts.WorkspaceMembership,
      destination_attribute: :workspace_id
    )
  end

  validations do
    validate(match(:slug, ~r/^[a-z0-9-]+$/),
      message: "slug must only contain lowercase letters, numbers and hyphens"
    )
  end

  actions do
    default_accept(:*)
    defaults([:read, :update])

    create :create do
      description("创建工作台（仅平台管理员）；自动 seed 角色并建立 Owner 成员资格")

      accept([:slug, :name, :join_policy, :sponsorship_enabled])

      change(
        after_action(fn changeset, workspace, _context ->
          tenant = workspace.id

          roles = [
            {:owner, "工作台所有者：拥有全部管理权限"},
            {:admin, "工作台管理员：成员管理、角色分配"},
            {:member, "普通成员：可访问工作台内容"}
          ]

          role_records =
            Enum.map(roles, fn {name, description} ->
              Ash.create!(Cgc2046.Accounts.Role, %{name: name, description: description},
                tenant: tenant,
                authorize?: false
              )
            end)

          actor = get_in(changeset.context, [:private, :actor])

          if actor do
            owner_role = Enum.find(role_records, &(&1.name == :owner))

            membership =
              Ash.create!(Cgc2046.Accounts.WorkspaceMembership, %{user_id: actor.id},
                tenant: tenant,
                authorize?: false
              )

            Ash.create!(
              Cgc2046.Accounts.MembershipRole,
              %{
                membership_id: membership.id,
                role_id: owner_role.id
              },
              tenant: tenant,
              authorize?: false
            )

            {:ok, workspace}
          else
            {:ok, workspace}
          end
        end)
      )
    end

    read :get_by_slug do
      description("按 slug 获取工作台")
      get_by([:slug])
    end

    read :get_by_id do
      description("按 id 获取工作台")
      get_by([:id])
    end

    read :me_workspaces do
      description("当前用户可进入的工作台列表（成员资格并集 + 创建者）")

      filter(expr(exists(memberships, user_id == ^actor(:id))))

      prepare(build(load: [:my_role_names, :my_membership_id, :can_access]))
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

    # open/request：已认证用户可定向读取（匿名不可）
    policy [action_type(:read), expr(join_policy in [:open, :request])] do
      authorize_if(actor_present())
    end

    # invite_only：仅成员可读；平台管理员可读全部
    # 注意：relates_to_actor_via 需要完整路径 [:memberships, :user]，
    # 否则 Ash 生成 membership.id == actor.id（主键直匹配）导致成员读不到（#66 review 发现）
    policy [action_type(:read), expr(join_policy == :invite_only)] do
      authorize_if(relates_to_actor_via([:memberships, :user]))
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end
  end

  graphql do
    type(:workspace)

    queries do
      read_one(:get_workspace, :get_by_slug, description: "按 slug 获取工作台（需登录）")

      read_one(:get_workspace_by_id, :get_by_id, description: "按 id 获取工作台（需登录）")

      list(:me_workspaces, :me_workspaces, description: "当前用户可进入的工作台列表（成员资格 + 创建者）")
    end

    mutations do
      create(:create_workspace, :create, description: "创建工作台（仅平台管理员）")

      update(:update_workspace, :update, description: "更新工作台（平台管理员）")
    end
  end
end
