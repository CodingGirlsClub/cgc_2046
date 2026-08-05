defmodule Cgc2046.Accounts.Workspace do
  @moduledoc """
  全局工作台资源。

  领域模型（docs/01-定稿设计/领域模型定稿.md ER §5.2）：
  - `slug`：全局唯一、用户可读标识（创建者提供，格式 `^[a-z0-9-]+$`）
  - `join_policy`：加入策略三态 `open`（公开直接加入）/ `request`（公开申请审批）/ `invite_only`（私密仅邀请），默认 `request`
  - `sponsorship_enabled`：是否开放赞助入口，默认开

  权限（#62 + #64，Leader 已拍板）：
  - 创建：仅平台管理员；创建时自动 seed 角色（owner/admin/member/tutor/volunteer/learner）并建立 Owner 成员资格（#64 + G1）
  - 读取：open/request 工作台对已认证用户可定向查询；invite_only 仅成员/管理员/平台管理员可读（非成员返回 null/forbidden，不可发现）
  - 更新：Owner/Admin（多角色并集）或平台管理员可改（#78：放开 join_policy 修改，
    对应能力 `:update_join_policy`，见 Rbac 能力表）
  - `me_workspaces`：返回当前用户可进入（成员或创建者）的工作台列表，供前端 #63 使用
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  require Ash.Query

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

    # #1 能力接口收敛：my_abilities 随 meWorkspaces 下发（退役独立 myAbilities query）。
    # 语义与 Rbac.abilities/2 完全一致（含非成员分支）：成员路径由共享纯函数
    # abilities_for/2 派生；非成员平台管理员豁免 view/access/create_workspace。
    calculate(
      :my_abilities,
      {:array, :string},
      {Cgc2046.Accounts.Calculations.CurrentMembershipInfo, key: :my_abilities},
      public?: true,
      description: "当前用户在该工作台的能力列表（能力接口，与 Rbac.abilities/2 一致）"
    )

    # P1-4 memberCount：Repo 层批量 count（不经 membership read policy）。
    # 见 BypassReads（旁路读取面）moduledoc：expr(count)/aggregate 子查询会被
    # read policy 过滤成仅 actor 自己（SimpleCheck 子查询取不到 workspace_id）。
    calculate(
      :member_count,
      :integer,
      {Cgc2046.Accounts.Calculations.MemberCount, []},
      public?: true,
      description: "成员数量（P1 计算字段，SQL count(memberships)）"
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

          # 角色模板从 Role 模块单源取（role_descriptions/0），避免重复六角色字面量（G2 收敛）
          role_records =
            Cgc2046.Accounts.Role.role_descriptions()
            |> Enum.map(fn {name, description} ->
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

      prepare(build(load: [:my_role_names, :my_membership_id, :can_access, :member_count]))
    end

    # G13：open 直接加入。
    # 用 generic action 而非 read：此操作创建 Membership + MembershipRole，是写操作，
    # GraphQL 层暴露为 mutation（joinWorkspace），符合"mutation 改状态"的语义。
    # 旧实现挂在 read :join 上暴露成 query，违反 GraphQL query 无副作用约定。
    action :join, :struct do
      description("直接加入公开工作台（join_policy==:open）→ 建 Membership + learner 角色")

      constraints(instance_of: __MODULE__)

      argument(:workspace_id, :uuid,
        allow_nil?: false,
        description: "目标工作台 ID"
      )

      run(fn input, _context ->
        workspace_id = input.arguments.workspace_id
        actor = input.context[:private][:actor]

        workspace = Ash.get!(__MODULE__, workspace_id, authorize?: false)

        case workspace.join_policy do
          :open ->
            if actor do
              tenant = workspace_id

              # 幂等检查：已是成员则跳过建 Membership（不报错，直接返回 workspace）。
              # fail-closed：读失败时返回错误，不降级成"无成员资格可建"——
              # 否则 DB 读异常会被当成"可以建"继续插入，掩盖真实错误。
              case Cgc2046.Accounts.WorkspaceMembership
                   |> Ash.Query.for_read(:read)
                   |> Ash.Query.filter(user_id: actor.id)
                   |> Ash.read_one(tenant: tenant, actor: actor, authorize?: false) do
                {:ok, nil} ->
                  # 并发下另一请求可能已插入，DB unique 约束 (wm_unique_ws_user_idx
                  # on user_id) 兜底。unique 冲突当幂等成功返回——join 语义本就幂等
                  # （区别于 join_request approve 把重复审批当业务错误）。
                  # 非 unique 的真实 DB 故障（连接断、磁盘满）必须上抛，不能吞成「成功」，
                  # 否则用户以为加入成功实际无 membership（静默数据丢失）。
                  # ponytail: 不包事务——MembershipRole 用 Ash.create! 失败会 raise
                  # 留孤儿 membership，但 learner 新 membership 不命中 unique 冲突，
                  # 仅 DB 连接断等极端情况触发，概率极低；与 join_request approve
                  # 同款范式。若需强一致，升级为 Ash.transaction 包两次写。
                  case Cgc2046.Accounts.WorkspaceMembership
                       |> Ash.Changeset.for_create(:create, %{user_id: actor.id})
                       |> Ash.create(tenant: tenant, actor: actor, authorize?: false) do
                    {:ok, membership} ->
                      roles = Ash.read!(Cgc2046.Accounts.Role, tenant: tenant, authorize?: false)
                      learner_role = Enum.find(roles, &(&1.name == :learner))

                      if learner_role do
                        Ash.create!(
                          Cgc2046.Accounts.MembershipRole,
                          %{
                            membership_id: membership.id,
                            role_id: learner_role.id
                          },
                          tenant: tenant,
                          authorize?: false
                        )
                      end

                    # unique 冲突 → 幂等成功
                    {:error, error} ->
                      if Cgc2046.Accounts.MembershipContext.unique_membership_conflict?(error) do
                        :ok
                      else
                        {:error, error}
                      end
                  end

                {:ok, _membership} ->
                  :ok

                {:error, read_error} ->
                  {:error, read_error}
              end
            else
              :ok
            end

            # 上面块返回 {:error, _}（读失败）时传播错误，否则返回 workspace
            |> case do
              {:error, _} = err -> err
              _ -> {:ok, workspace}
            end

          :request ->
            {:error,
             Ash.Error.Changes.InvalidAttribute.exception(
               field: :join_policy,
               message:
                 "This workspace requires an application. Please use createJoinRequest instead."
             )}

          :invite_only ->
            {:error,
             Ash.Error.Changes.InvalidAttribute.exception(
               field: :join_policy,
               message: "This workspace is invite-only. Please use an invitation link to join."
             )}
        end
      end)
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
      # #78：Owner/Admin（多角色并集）可更新（含 join_policy）；
      # 平台管理员现状能力不回收（二者取并）
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
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

    # G13 join：generic action 无被查询记录集，无法用基于记录字段的策略；
    # 已认证用户即可调用，join_policy 校验在 action 的 run 内完成。
    policy action(:join) do
      authorize_if(actor_present())
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

      update(:update_workspace, :update, description: "更新工作台（Owner/Admin 或平台管理员）")

      # join 为 generic action，用 action 暴露成 mutation（写操作语义）
      action(:join_workspace, :join,
        description: "直接加入公开工作台（join_policy==:open）→ 建 Membership + learner 角色"
      )
    end
  end
end
