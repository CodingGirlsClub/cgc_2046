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
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
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
    # 由共享纯函数 Rbac.abilities_for/2 派生（含非成员分支）：成员路径从角色并集
    # 派生；非成员平台管理员豁免 view/access/create_workspace。
    calculate(
      :my_abilities,
      {:array, :string},
      {Cgc2046.Accounts.Calculations.CurrentMembershipInfo, key: :my_abilities},
      public?: true,
      description: "当前用户在该工作台的能力列表（能力接口，与 Rbac.abilities_for/2 一致）"
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

  # #116 R10a：workspace 直接创建的留痕 metadata 纯函数（供 LogAdminAction change
  # 声明以远程捕获引用；DSL 实体 opts 需可转义：匿名 fn 与私有函数捕获都不可，
  # 须为 public 且定义在 actions 之前）。
  @doc false
  def workspace_log_metadata(_changeset, workspace) do
    %{slug: workspace.slug, name: workspace.name}
  end

  actions do
    default_accept(:*)
    defaults([:read, :update])

    create :create do
      description(
        "创建工作台（仅平台管理员）；自动 seed 角色并建立 Owner 成员资格（默认 actor，可指定 owner_user_id 或 owner_email）"
      )

      accept([:slug, :name, :join_policy, :sponsorship_enabled])

      argument(:owner_user_id, :uuid,
        allow_nil?: true,
        description: "指定已有用户为 Owner（替代 actor.id 建 Owner membership）"
      )

      argument(:owner_email, :string,
        allow_nil?: true,
        description: "邀请新用户为 Owner（创建 preauthorized [:owner] 的 Invitation，pending-owner）"
      )

      # owner_email 路径创建的 pending-owner 邀请明文 token（一次性返回，不落库）
      metadata(:owner_invitation_token, :string,
        allow_nil?: true,
        description: "pending-owner 邀请明文 token（仅创建时返回一次，不落库）"
      )

      change(
        after_action(fn changeset, workspace, _context ->
          tenant = workspace.id

          # 角色模板从 Role 模块单源取（role_descriptions/0），避免重复六角色字面量（G2 收敛）。
          # reduce_while + Ash.create（非 bang）：任一角色创建失败短路返回 {:error, ...}，
          # 走 ash_graphql to_errors → 结构化错误；after_action 在父 create 事务内，
          # 返回 {:error, _} 会 rollback 整个 workspace 创建，不留孤儿。
          role_records =
            Enum.reduce_while(Cgc2046.Accounts.Role.role_descriptions(), [], fn {name,
                                                                                 description},
                                                                                acc ->
              case Ash.create(Cgc2046.Accounts.Role, %{name: name, description: description},
                     tenant: tenant,
                     authorize?: false
                   ) do
                {:ok, role} -> {:cont, [role | acc]}
                {:error, error} -> {:halt, {:error, error}}
              end
            end)
            |> case do
              {:error, _} = err -> err
              roles -> {:ok, roles}
            end

          result =
            with {:ok, role_records} <- role_records do
              # Owner 来源优先级：owner_user_id > owner_email > actor.id（D1）
              # owner_user_id：建 Owner membership 给该用户；owner_email：建 pending-owner
              # Invitation（preauthorized [:owner]）；都无：回退 actor（现有行为）。
              owner_user_id = Ash.Changeset.get_argument(changeset, :owner_user_id)
              owner_email = Ash.Changeset.get_argument(changeset, :owner_email)
              actor = get_in(changeset.context, [:private, :actor])

              cond do
                owner_user_id ->
                  create_owner_membership(workspace, tenant, owner_user_id, role_records)

                owner_email && actor ->
                  create_owner_invitation(workspace, tenant, actor, owner_email)

                actor ->
                  create_owner_membership(workspace, tenant, actor.id, role_records)

                true ->
                  # actor 为 nil：无 actor 时仅 seed 角色，不建 Owner 成员资格/邀请
                  {:ok, workspace}
              end
            else
              {:error, _} = err -> err
            end

          result
        end)
      )

      # #116 R10a：治理留痕（workspace 直接创建；approve 路径无 actor 时
      # on_missing_actor: :skip 不落行，天然不双记——approve 的留痕由 approve 自己的
      # after_action 落 application_approve，该不变量由 admin_action_log_test 钉死）。
      # 留痕失败上抛回滚整个创建（fail-closed）。
      change(
        {Cgc2046.Changes.LogAdminAction,
         action: :workspace_create,
         target_type: :workspace,
         on_missing_actor: :skip,
         metadata: &__MODULE__.workspace_log_metadata/2}
      )
    end

    # #114：重指派 Owner（仅平台管理员，pending-owner 期间）。
    # 语义 = 原子地「撤销当前 active Owner 邀请 + 改指现有用户 / 发新邀请」。
    # 不走 RBAC assignRoles（「只有 Owner 能授/撤 owner」不变量，pending-owner 无 Owner
    # 故走不通，rbac.ex validate_owner_removal!），复用 create 的
    # create_owner_membership / create_owner_invitation 私有路径，同一事务。
    update :reassign_owner do
      description("重指派 Owner（仅平台管理员，pending-owner 期间）：撤销 active Owner 邀请 + 改指现有用户或发新邀请")
      require_atomic?(false)
      accept([])

      argument(:owner_user_id, :uuid,
        allow_nil?: true,
        description: "改指现有用户为 Owner（建 Owner membership）"
      )

      argument(:owner_email, :string,
        allow_nil?: true,
        description: "改发 pending-owner 邀请给新邮箱（preauthorized [:owner]，带 expires_at）"
      )

      # owner_email 分支新邀请的明文 token（一次性返回，不落库，同 create 的交付语义）
      metadata(:owner_invitation_token, :string,
        allow_nil?: true,
        description: "新 pending-owner 邀请明文 token（仅返回一次，不落库）"
      )

      change(
        after_action(fn changeset, workspace, _context ->
          owner_user_id = Ash.Changeset.get_argument(changeset, :owner_user_id)
          owner_email = Ash.Changeset.get_argument(changeset, :owner_email)
          actor = get_in(changeset.context, [:private, :actor])
          tenant = workspace.id

          cond do
            is_nil(owner_user_id) and is_nil(owner_email) ->
              {:error,
               Ash.Error.Changes.InvalidAttribute.exception(
                 field: :owner_user_id,
                 message: "必须提供 owner_user_id 或 owner_email 之一"
               )}

            owner_user_id && owner_email ->
              {:error,
               Ash.Error.Changes.InvalidAttribute.exception(
                 field: :owner_user_id,
                 message: "owner_user_id 与 owner_email 只能提供一个"
               )}

            Cgc2046.Accounts.MembershipContext.owner_count(tenant) > 0 ->
              {:error,
               Ash.Error.Changes.InvalidAttribute.exception(
                 field: :status,
                 message: "工作台已有 Owner，重指派仅适用于 pending-owner 期间"
               )}

            true ->
              # 撤销旧邀请 → 入座新 Owner → 治理留痕，任一失败回滚整个 reassign。
              # 撤销 fail-closed：邀请被并发 accept（used）时 :revoke 状态守卫报错，
              # 整个 reassign 回滚，不出现双 Owner。
              with :ok <- revoke_active_owner_invitations(tenant),
                   {:ok, workspace} <-
                     seat_new_owner(workspace, tenant, actor, owner_user_id, owner_email),
                   {:ok, _log} <-
                     Cgc2046.Changes.LogAdminAction.log(changeset, workspace, %{
                       action: :owner_reassign,
                       target_type: :workspace,
                       target_id: workspace.id,
                       metadata:
                         if(owner_user_id,
                           do: %{owner_user_id: owner_user_id},
                           else: %{owner_email: owner_email}
                         )
                     }) do
                {:ok, workspace}
              end
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

        case Ash.get(__MODULE__, workspace_id, authorize?: false) do
          {:ok, nil} ->
            {:error,
             Ash.Error.Query.NotFound.exception(
               path: [__MODULE__, workspace_id],
               message: "Workspace not found"
             )}

          {:ok, workspace} ->
            case workspace.join_policy do
              :open ->
                # #115 ownerless 门控（方案 B）：pending-owner（Owner 邀请未接受）期间阻断
                # 直接加入——ownerless 时工作台无任何管理角色，先入座会留下无人管理的成员。
                # Owner 接受邀请入座后 owner_count > 0，门控自动解除。
                if Cgc2046.Accounts.MembershipContext.owner_count(workspace_id) == 0 do
                  {:error,
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :status,
                     message: "工作台尚未开放加入（Owner 未就位）"
                   )}
                else
                  if actor do
                    # 入座委托 MembershipContext.admit_member/3（入座不变量唯一实现）。
                    # join 语义幂等：已是成员 / 并发 unique 冲突 → 成功返回 workspace（不报错），
                    # 区别于 join_request approve 把重复审批当业务错误。真 DB 故障上抛。
                    # ponytail: generic action :join 默认 transaction?: false（action/action.ex:20），
                    # 两次写不在同一事务——MembershipRole 创建失败时 Membership 已 commit，
                    # 留孤儿 membership。已从 raise-500 改为结构化错误，但孤儿未消除；
                    # learner 新 membership 不命中 unique 冲突，仅 DB 连接断等极端情况触发，概率极低。
                    # 若需强一致，给 action :join 加 transaction?: true（ash_postgres 支持跨资源事务）。
                    case Cgc2046.Accounts.MembershipContext.admit_member(
                           actor.id,
                           workspace_id,
                           [:learner],
                           on_conflict: :idempotent
                         ) do
                      {:ok, _membership} -> {:ok, workspace}
                      {:error, _} = err -> err
                    end
                  else
                    {:ok, workspace}
                  end
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
                   message:
                     "This workspace is invite-only. Please use an invitation link to join."
                 )}
            end
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
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    policy action_type(:update) do
      # #78：Owner/Admin（多角色并集）可更新（含 join_policy）；
      # 平台管理员现状能力不回收（二者取并）
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    # open/request：已认证用户可定向读取（匿名不可）
    policy [action_type(:read), expr(join_policy in [:open, :request])] do
      authorize_if(actor_present())
    end

    # invite_only：仅成员可读；平台管理员可读全部
    policy [action_type(:read), expr(join_policy == :invite_only)] do
      authorize_if({Cgc2046.Policies.ActorIsWorkspaceMemberVia, path: []})
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    # G13 join：generic action 无被查询记录集，无法用基于记录字段的策略；
    # 已认证用户即可调用，join_policy 校验在 action 的 run 内完成。
    policy action(:join) do
      authorize_if(actor_present())
    end

    # #114 reassign_owner：仅平台管理员。action_type(:update) 的 Owner/Admin 授权会连带
    # 匹配本 action，必须用 forbid_unless 显式封堵（forbid 优先）；同时 Ash 策略按
    # 「所有适用 policy 均须授权」求值，authorize_if 与 forbid_unless 缺一不可。
    policy action(:reassign_owner) do
      forbid_unless(Cgc2046.Policies.PlatformAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
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

      update(:reassign_workspace_owner, :reassign_owner,
        description: "重指派 Owner（仅平台管理员，pending-owner 期间）：撤销 active Owner 邀请 + 改指现有用户或发新邀请"
      )

      # join 为 generic action，用 action 暴露成 mutation（写操作语义）
      action(:join_workspace, :join,
        description: "直接加入公开工作台（join_policy==:open）→ 建 Membership + learner 角色"
      )
    end
  end

  # Phase 4（D1）：为指定 user_id 落定 Owner 席位（membership + Owner 角色）。
  # 与 create after_action 内联逻辑等价，抽出供 owner_user_id 与 actor 回退两分支复用。
  # #114 review 修复：目标用户已是本工作台成员时（reassign 晋升场景：pending-owner
  # 期间经成员邀请/CLI 等路径先入座的非 Owner 成员）不新建 membership——否则撞
  # wm_unique_ws_user_idx 唯一约束，admin 拿到原始 DB 报错且晋升静默失败；改为在
  # 既有 membership 上补 Owner 角色（多角色并集，保留原角色）。该用户不可能已持
  # Owner 角色（:reassign_owner 的 owner_count 守卫前置拦截；:create 路径工作台新建
  # 无成员），unique_membership_role 仅作 fail-closed 兜底。
  defp create_owner_membership(workspace, tenant, user_id, role_records) do
    owner_role = Enum.find(role_records, &(&1.name == :owner))

    case Cgc2046.Accounts.WorkspaceMembership
         |> Ash.Query.filter(workspace_id == ^tenant and user_id == ^user_id)
         |> Ash.read(tenant: tenant, authorize?: false) do
      {:ok, []} ->
        with {:ok, membership} <-
               Ash.create(Cgc2046.Accounts.WorkspaceMembership, %{user_id: user_id},
                 tenant: tenant,
                 authorize?: false
               ),
             {:ok, _} <- create_membership_role(membership, owner_role, tenant) do
          {:ok, workspace}
        end

      {:ok, [membership | _]} ->
        case create_membership_role(membership, owner_role, tenant) do
          {:ok, _} -> {:ok, workspace}
          {:error, _} = err -> err
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_membership_role(membership, role, tenant) do
    Ash.create(
      Cgc2046.Accounts.MembershipRole,
      %{membership_id: membership.id, role_id: role.id},
      tenant: tenant,
      authorize?: false
    )
  end

  # pending-owner 邀请有效期（天），对齐既有邀请约定 MiniprogramCode.@default_expiry_days。
  # 过期由 ApprovalExpiryWorker 落库 expired（#114）；读时 effective_status 兜底。
  @owner_invitation_expiry_days 7

  # Phase 4（D5/D3）：为 owner_email 创建 pending-owner Invitation（preauthorized [:owner]）。
  # inviter_id = actor（platform_admin）；Invitation 是租户资源，须带 tenant。
  # authorize?: false 调用（父 create 事务内，角色 seed 同款）；create policy 仍加
  # platform_admin bypass 供外部（GraphQL Phase 5）直接创建时使用。
  # 明文 token 写入 workspace metadata（owner_invitation_token）一次性交付，
  # 供 GraphQL 层把邀请链接发给目标邮箱（R5）。
  # #114：创建即带 expires_at（@owner_invitation_expiry_days 天），不再永不过期。
  defp create_owner_invitation(workspace, tenant, actor, owner_email) do
    case Cgc2046.Accounts.Invitation
         |> Ash.Changeset.for_create(:create, %{
           workspace_id: workspace.id,
           inviter_id: actor.id,
           target_email: owner_email,
           preauthorized_role_names: [:owner],
           expires_at: DateTime.add(DateTime.utc_now(), @owner_invitation_expiry_days, :day)
         })
         |> Ash.create(actor: actor, tenant: tenant, authorize?: false) do
      {:ok, invitation} ->
        token = invitation.__metadata__[:plain_token]
        {:ok, Ash.Resource.put_metadata(workspace, :owner_invitation_token, token)}

      {:error, _} = err ->
        err
    end
  end

  # #114：撤销该工作台全部 active 且 preauthorized [:owner] 的邀请（reassign 前置步骤）。
  # 不传 actor 调用（authorize?: false）：避免触发 :revoke 的 owner_invitation_cancel
  # 条件留痕 hook——取消语义已被 reassign 自己的 :owner_reassign 留痕覆盖，不双记。
  # used/revoked 等非法转换由 :revoke 状态守卫报错（并发 accept 竞态 → reassign 回滚）。
  defp revoke_active_owner_invitations(tenant) do
    Cgc2046.Accounts.Invitation
    |> Ash.Query.filter(workspace_id == ^tenant and status == :active)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(:owner in (&1.preauthorized_role_names || [])))
    |> Enum.reduce_while(:ok, fn invitation, :ok ->
      case invitation
           |> Ash.Changeset.for_update(:revoke, %{})
           |> Ash.update(tenant: tenant, authorize?: false) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # #114：reassign 入座分支——现有用户建 Owner membership（复用 create 私有路径）；
  # 邮箱发新 pending-owner 邀请（带 expires_at，token 经 metadata 一次性交付）。
  # owner_email 分支 actor 为 nil（CLI 无 actor 调用）时报结构化错误而非崩溃。
  defp seat_new_owner(workspace, tenant, _actor, owner_user_id, nil) do
    owner_role =
      Cgc2046.Accounts.Role
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.find(&(&1.name == :owner))

    create_owner_membership(workspace, tenant, owner_user_id, [owner_role])
  end

  defp seat_new_owner(_workspace, _tenant, nil, nil, owner_email) when not is_nil(owner_email) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :owner_email,
       message: "owner_email 重指派需要 actor（邀请人）；CLI 无 actor 调用请改用 owner_user_id"
     )}
  end

  defp seat_new_owner(workspace, tenant, actor, nil, owner_email) do
    create_owner_invitation(workspace, tenant, actor, owner_email)
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:tenancy)
    label_field(:name)
    show_calculations([:member_count])
    table_columns([:id, :slug, :name, :join_policy, :sponsorship_enabled, :inserted_at])
  end
end
