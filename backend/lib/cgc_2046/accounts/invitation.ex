defmodule Cgc2046.Accounts.Invitation do
  @moduledoc """
  工作台邀请资源（#31）。

  领域模型（docs/01-定稿设计/领域模型定稿.md ER §INVITATION/JOIN_REQUEST）：
  Invitation 是租户资源（workspace_id），表示工作台成员向外部用户发出的加入邀请。
  邀请流程：active → used（受邀人确认加入）/ revoked / expired。

  字段：
  - `token_hash`：邀请令牌的 SHA256 哈希（不存明文）
  - `inviter_id`：邀请人（全局用户）ID
  - `target_email`：目标邮箱（可选，空=公开链接）
  - `preauthorized_role_names`：预授权角色名数组（可选）
  - `expires_at`：过期时间（可选）
  - `status`：active | used | revoked | expired
  - `accepted_by`：接受人（全局用户）ID
  - `accepted_at`：接受时间

  决策 5：Volunteer 不可预授权 Admin 级角色（owner/admin），change 校验。
  决策 6：无预授权角色时建 Membership 不分配角色（待 Owner 手动 assign_roles）。
  决策 8：validate 绕过 workspace read policy，token 有效性证明访问权。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

  require Ash.Query

  alias Cgc2046.ApprovalClaim

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:token_hash, :string,
      allow_nil?: false,
      public?: true,
      description: "邀请令牌的 SHA256 哈希"
    )

    attribute(:inviter_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "邀请人（全局用户）ID"
    )

    attribute(:target_email, :string,
      allow_nil?: true,
      public?: true,
      description: "目标邮箱（空=公开链接）"
    )

    attribute(:preauthorized_role_names, {:array, :atom},
      allow_nil?: true,
      public?: true,
      constraints: [items: [one_of: Cgc2046.Accounts.Role.role_names()]],
      description: "预授权角色名数组（可选）"
    )

    attribute(:expires_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      description: "过期时间（可选）"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :active,
      public?: true,
      constraints: [one_of: [:active, :used, :revoked, :expired]],
      description: "邀请状态"
    )

    attribute(:accepted_by, :uuid,
      allow_nil?: true,
      public?: true,
      description: "接受人（全局用户）ID"
    )

    attribute(:accepted_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      description: "接受时间"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)

    # 允许跨租户读取，隔离由 policy 保证
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)

    belongs_to(:inviter, Cgc2046.Accounts.User, define_attribute?: false)

    belongs_to(:accepted_by_user, Cgc2046.Accounts.User,
      define_attribute?: false,
      source_attribute: :accepted_by,
      description: "接受人（全局用户）"
    )
  end

  calculations do
    # 读时派生过期状态：仅 active 且 expires_at < now 视为 expired，
    # 避免 read 副产生写负载。used/revoked 等显式终结状态保持原样（与原 preparations WHERE status='active' 一致）。
    # DB 中 status 保持 active，落库过期留待主动调度。
    calculate(:effective_status, :string,
      public?: true,
      calculation: fn invitations, _opts ->
        now = DateTime.utc_now()

        Enum.map(invitations, fn invitation ->
          if invitation.status == :active &&
               invitation.expires_at &&
               DateTime.compare(invitation.expires_at, now) == :lt do
            "expired"
          else
            to_string(invitation.status)
          end
        end)
      end
    )

    # 工作台预览字段（决策 8）：供受邀人在 invite_only 场景下无需读 workspace 即可看到
    # 要加入哪个工作台。三个 calculation 共享同一 workspace 关系 load，Ash 把同关系路径
    # 合并为一次批量查询（validate 单条 1 查询，list N 条也只 1 次批量 fetch），
    # 消除原各自 Ash.get! 的 3×冗余查询。invite_only + 非成员仍能读到预览
    # （见 invitation_test.exs "invite_only workspace is previewable via validate by non-member"），
    # 因 :validate bypass policy 放行 Invitation 读取，workspace 关系 load 在此路径下
    # 不被 Workspace read policy 拦截——保持原 authorize?: false 的绕过语义。
    calculate(:workspace_name, :string,
      public?: true,
      load: [workspace: [:name, :slug, :join_policy]],
      calculation: fn invitations, _opts ->
        Enum.map(invitations, fn invitation ->
          # match? 守卫排除 Ash.ForbiddenField（struct truthy 会 KeyError）与 nil；
          # || nil 把 match? 的 false 落回 nil，避免 Ash String 把 false cast 成 "false"
          (match?(%Cgc2046.Accounts.Workspace{}, invitation.workspace) &&
             invitation.workspace.name) || nil
        end)
      end
    )

    calculate(:workspace_slug, :string,
      public?: true,
      load: [workspace: [:name, :slug, :join_policy]],
      calculation: fn invitations, _opts ->
        Enum.map(invitations, fn invitation ->
          (match?(%Cgc2046.Accounts.Workspace{}, invitation.workspace) &&
             invitation.workspace.slug) || nil
        end)
      end
    )

    calculate(:workspace_join_policy, :string,
      public?: true,
      load: [workspace: [:name, :slug, :join_policy]],
      calculation: fn invitations, _opts ->
        Enum.map(invitations, fn invitation ->
          (match?(%Cgc2046.Accounts.Workspace{}, invitation.workspace) &&
             to_string(invitation.workspace.join_policy)) || nil
        end)
      end
    )
  end

  identities do
    identity(:unique_token_hash, [:token_hash])
  end

  postgres do
    table("invitations")
    repo(Cgc2046.Repo)
  end

  # 过期判定双轨（#114）：ApprovalExpiryWorker 经 :expire action 主动落库过期；
  # 读时 effective_status 计算作为兜底（扫描间隙内已过点的 active 行仍派生 expired），
  # 不在 read 时执行 UPDATE。

  # #114：revoke 留痕的 target_id/skip_unless/metadata 纯函数（供 LogAdminAction change
  # 声明以远程捕获引用；DSL 实体 opts 需可转义：匿名 fn 与私有函数捕获都不可，
  # 须为 public 且定义在 actions 之前）。skip_unless = actor 是 platform_admin 且
  # preauthorized 含 :owner；成员撤销自己的普通邀请不记。
  @doc false
  def invitation_log_target_id(_changeset, invitation), do: invitation.workspace_id

  @doc false
  def invitation_log_skip_unless(changeset, invitation) do
    actor = get_in(changeset.context, [:private, :actor])

    Cgc2046.Policies.PlatformAdmin.platform_admin?(actor) and
      :owner in (invitation.preauthorized_role_names || [])
  end

  @doc false
  def invitation_log_metadata(_changeset, invitation) do
    %{invitation_id: invitation.id, target_email: invitation.target_email}
  end

  actions do
    default_accept([])
    defaults([:read])

    create :create do
      description("创建邀请（Owner/Admin/Volunteer；Volunteer 不可预授权 Admin 级角色）")
      accept([:target_email, :preauthorized_role_names, :expires_at])

      argument(:workspace_id, :uuid,
        allow_nil?: false,
        description: "目标工作台 ID"
      )

      argument(:inviter_id, :uuid,
        allow_nil?: false,
        description: "邀请人 ID"
      )

      # 手动解析 argument（非原子模式，set_attribute 的 change/3 不解析 {:_arg, _}）
      # 使用 force_change_attribute（同 set_attribute 内部实现）绕过 writable?: false 并执行类型转换
      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :workspace_id,
          Ash.Changeset.get_argument(changeset, :workspace_id)
        )
        |> Ash.Changeset.force_change_attribute(
          :inviter_id,
          Ash.Changeset.get_argument(changeset, :inviter_id)
        )
      end)

      change(set_attribute(:status, :active))

      # 生成 token 并存储 hash；明文 token 仅通过 metadata 一次性返回，不落库
      change(fn changeset, _context ->
        token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

        changeset
        |> Ash.Changeset.change_attribute(:token_hash, token_hash)
        |> Ash.Changeset.put_context(:plain_token, token)
      end)

      # 校验 Volunteer 不可预授权 admin/owner（决策 5）
      change(Cgc2046.Changes.ValidateInviterRolePreauthorization)

      # after_action 把明文 token 注入 record metadata（AshGraphql 暴露为 mutation result 的 metadata.plainToken）
      change(
        after_action(fn changeset, invitation, _context ->
          token = changeset.context[:plain_token]
          {:ok, Ash.Resource.put_metadata(invitation, :plain_token, token)}
        end)
      )

      # 明文 token 仅创建时一次性返回，不落库（与 user.ex JWT token 范式一致）
      metadata(:plain_token, :string,
        allow_nil?: false,
        description: "明文邀请令牌（仅创建时返回一次，不落库）"
      )
    end

    update :revoke do
      description("撤销邀请（邀请人本人或 Owner/Admin 或平台管理员）")
      require_atomic?(false)

      # 状态守卫：仅允许 active → revoked。before_action 重新加载记录以确保最新状态
      # （复用 :accept action 的 before_action 重新加载范式，见下方 :accept）。
      # - used：membership 已建立，revoke 是假动作且会把 status 从 used 改成 revoked，
      #   篡改 accept 的状态判断语义并留下 accepted_by/accepted_at 残留 → 拒
      # - revoked：重复撤销 → 拒（before_action 无法表达幂等成功，统一非 active 拒绝）
      # - active 且 expires_at < now（读时 expired）：仍允许 revoke。DB status 仍 active，
      #   属 active→revoked 合法转换；主动撤销覆盖自然过期语义（见 invitation_test.exs:743
      #   "effective_status 不覆盖显式终结状态"），与 used/revoked 的非法转换不同。
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          invitation = Ash.get!(Cgc2046.Accounts.Invitation, cs.data.id, authorize?: false)

          cond do
            invitation.status == :used ->
              cs
              |> Ash.Changeset.add_error(
                Ash.Error.Changes.InvalidAttribute.exception(
                  field: :status,
                  message: "Cannot revoke an already used invitation"
                )
              )

            invitation.status == :revoked ->
              cs
              |> Ash.Changeset.add_error(
                Ash.Error.Changes.InvalidAttribute.exception(
                  field: :status,
                  message: "Invitation has already been revoked"
                )
              )

            invitation.status == :active ->
              cs

            true ->
              cs
              |> Ash.Changeset.add_error(
                Ash.Error.Changes.InvalidAttribute.exception(
                  field: :status,
                  message: "Cannot revoke invitation in status #{invitation.status}"
                )
              )
          end
        end)
      end)

      change(set_attribute(:status, :revoked))

      # #114：platform admin 撤销 Owner 预授权邀请（pending-owner 取消）→ 治理留痕。
      # 条件挂接：actor 是 platform_admin 且 preauthorized 含 :owner；成员撤销自己的
      # 普通邀请不记。fail-closed：留痕失败回滚撤销本身（同一事务）。
      change(
        {Cgc2046.Changes.LogAdminAction,
         action: :owner_invitation_cancel,
         target_type: :workspace,
         target_id: &__MODULE__.invitation_log_target_id/2,
         skip_unless: &__MODULE__.invitation_log_skip_unless/2,
         metadata: &__MODULE__.invitation_log_metadata/2}
      )
    end

    update :expire do
      description("将过期邀请标记为 expired（内部使用，ApprovalExpiryWorker；不暴露 GraphQL）")
      require_atomic?(false)

      # 状态守卫：仅 active → expired（对齐 JoinRequest.:expire 与本资源 :revoke 范式）。
      # used/revoked/expired 均非法转换；before_action 读 data 快照拦截，并发终态变化由
      # 守卫拒绝（worker 侧预期竞态，记 warning 跳过）。
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          if cs.data.status == :active do
            cs
          else
            Ash.Changeset.add_error(
              cs,
              Ash.Error.Changes.InvalidAttribute.exception(
                field: :status,
                message: "Cannot expire invitation in status #{cs.data.status}"
              )
            )
          end
        end)
      end)

      change(set_attribute(:status, :expired))
    end

    read :validate do
      description("校验邀请 token，返回邀请信息 + 工作台预览（不落库，绕过 workspace read policy）")

      argument(:token, :string,
        allow_nil?: false,
        description: "明文邀请令牌"
      )

      prepare(fn query, _opts ->
        token = Ash.Query.get_argument(query, :token)

        if token do
          token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

          query
          |> Ash.Query.filter(token_hash: token_hash)
          |> Ash.Query.load([
            :effective_status,
            :workspace_name,
            :workspace_slug,
            :workspace_join_policy
          ])
          |> Ash.Query.ensure_selected([:workspace_id])
        else
          query
        end
      end)
    end

    update :accept do
      description("接受邀请→建 Membership + 预授权角色入座（决策 6）")
      require_atomic?(false)

      argument(:token, :string,
        allow_nil?: false,
        description: "明文邀请令牌（accept 须复验，证明调用方持有 token）"
      )

      # 原子 claim：token 复验 + 条件 UPDATE 合成一步（root-cause fix for #13 TOCTOU）。
      # token 校验先于状态：不匹配直接拒，不泄露 used/revoked/expired 状态信息。
      # 条件 UPDATE 把'读到 active 才置 used'下推成 DB 原子动作——行锁序列化并发 accept，
      # 0 行命中=已被并发 claim 或已处终结态（used/revoked/expired），统一报 already used。
      # 事务内执行：after_action 建 membership 失败时 status 置 used 一起回滚，不烧邀请。
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          token = Ash.Changeset.get_argument(cs, :token)
          token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

          if cs.data.token_hash != token_hash do
            cs
            |> Ash.Changeset.add_error(
              Ash.Error.Changes.InvalidAttribute.exception(
                field: :token,
                message: "Invalid invitation token"
              )
            )
          else
            actor = cs.context[:private][:actor]
            now = DateTime.utc_now()

            # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：token 复验 +
            # 条件 UPDATE 合成一步（root-cause fix for #13 TOCTOU）。token 校验先于状态
            # （Elixir 预检留调用方，防枚举）；条件 UPDATE 把'读到 active 才置 used'下推成
            # DB 原子动作——行锁序列化并发 accept，0 行命中=已被并发 claim 或已处终结态
            # （used/revoked/expired），统一报 already used；expires_at 守卫 =
            # ApprovalDeadline.not_expired?/2 的 SQL 端口。DB 错误经 {:error, {:database, _}}
            # 崩溃（保持原裸 SQL MatchError 同级的失败语义，错误映射留资源层 D3）。
            # 事务内执行：after_action 建 membership 失败时 status 置 used 一起回滚。
            # force_change_attribute 触发的二次 UPDATE 幂等（同事务行锁已持有）。
            case ApprovalClaim.claim(cs.data,
                   table: :invitations,
                   from: [:active],
                   set: [
                     status: "used",
                     accepted_at: {:arg, :now},
                     accepted_by: {:arg, :actor_id}
                   ],
                   deadline: {:expires_at, :future},
                   now: now,
                   actor_id: Cgc2046.Repo.uuid!(actor.id)
                 ) do
              {:ok, _returned} ->
                cs
                |> Ash.Changeset.force_change_attribute(:status, :used)
                |> Ash.Changeset.force_change_attribute(:accepted_at, now)
                |> Ash.Changeset.force_change_attribute(:accepted_by, actor.id)

              {:error, :not_claimed} ->
                cs
                |> Ash.Changeset.add_error(
                  Ash.Error.Changes.InvalidAttribute.exception(
                    field: :status,
                    message: "Invitation has already been used"
                  )
                )
            end
          end
        end)
      end)

      # 建 Membership + 预授权角色入座（委托 MembershipContext.admit_member/3，入座不变量唯一实现）。
      # after_action 回调签名 (changeset, record, context)，actor 在 changeset.context[:private][:actor]。
      # 入座 user = 接受人（actor），角色 = 预授权角色，冲突语义 = 业务错误（「你」视角文案）。
      change(
        after_action(fn changeset, invitation, _context ->
          admit_actor(changeset, invitation)
        end)
      )
    end

    update :accept_miniprogram do
      description("使用一次性小程序 scene 接受邀请并入座")
      require_atomic?(false)

      argument(:scene, :string, allow_nil?: false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          scene = Ash.Changeset.get_argument(cs, :scene)

          if Cgc2046.MiniprogramCode.valid_scene?(scene) do
            actor = cs.context[:private][:actor]
            now = DateTime.utc_now()

            {:ok, result} =
              Ecto.Adapters.SQL.query(
                Cgc2046.Repo,
                """
                UPDATE invitations AS i
                SET status = 'used', accepted_at = $1, accepted_by = $2
                FROM miniprogram_codes AS c
                WHERE i.id = $3 AND c.invitation_id = i.id AND c.scene = $4
                  AND i.status = 'active'
                  AND (i.expires_at IS NULL OR i.expires_at > $1)
                  AND c.expires_at > $1
                """,
                [now, Cgc2046.Repo.uuid!(actor.id), Cgc2046.Repo.uuid!(cs.data.id), scene]
              )

            if result.num_rows == 1 do
              cs
              |> Ash.Changeset.force_change_attribute(:status, :used)
              |> Ash.Changeset.force_change_attribute(:accepted_at, now)
              |> Ash.Changeset.force_change_attribute(:accepted_by, actor.id)
            else
              Ash.Changeset.add_error(
                cs,
                Ash.Error.Changes.InvalidAttribute.exception(
                  field: :scene,
                  message: "Invitation has already been used or scene has expired"
                )
              )
            end
          else
            Ash.Changeset.add_error(
              cs,
              Ash.Error.Changes.InvalidAttribute.exception(
                field: :scene,
                message: "Invalid scene"
              )
            )
          end
        end)
      end)

      change(after_action(&admit_actor/3))
    end
  end

  policies do
    # :create 限工作台成员（Owner/Admin/Volunteer），且 inviter_id 必须是 actor 本人；
    # pending-owner 邀请由专用 check 放行：仅平台管理员 + 预授权 owner。
    policy action(:create) do
      forbid_unless(expr(inviter_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.WorkspaceActorIsVolunteer)
      authorize_if(Cgc2046.Policies.PlatformAdminOwnerInvite)
    end

    # :revoke 限邀请人本人或 Owner/Admin；
    # pending-owner 期间无工作台 Owner/Admin，取消邀请由同一专用 check 放行。
    policy action(:revoke) do
      authorize_if(expr(inviter_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdminOwnerInvite)
    end

    # :validate 持 token 即可（不要求成员）
    # 使用 bypass 避免被 action_type(:read) 策略 AND 拦截
    bypass action(:validate) do
      authorize_if(actor_present())
    end

    # :accept 持 token 即可（不要求成员）
    policy action(:accept) do
      authorize_if(actor_present())
    end

    policy action(:accept_miniprogram) do
      authorize_if(actor_present())
    end

    # :read 邀请人本人可读自己的邀请；Owner/Admin 可读该工作台全部邀请；
    # #114 加 platform_admin bypass（admin 详情页 pending-owner badge 任意平台管理员可见）
    policy action_type(:read) do
      authorize_if(expr(inviter_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  defp admit_actor(changeset, invitation, _context), do: admit_actor(changeset, invitation)

  defp admit_actor(changeset, invitation) do
    actor = changeset.context[:private][:actor]

    case Cgc2046.Accounts.MembershipContext.admit_member(
           actor.id,
           invitation.workspace_id,
           invitation.preauthorized_role_names || [],
           on_conflict: :business_error,
           error_message: "你已是该工作台成员"
         ) do
      {:ok, _membership} -> {:ok, invitation}
      {:error, _} = error -> error
    end
  end

  graphql do
    type(:invitation)

    queries do
      list(:invitations, :read, description: "邀请列表（邀请人仅见自己；Owner/Admin 见全部）")

      read_one(:validate_invitation, :validate, description: "校验邀请 token，返回邀请信息 + 工作台预览")
    end

    mutations do
      create(:create_invitation, :create, description: "创建邀请（Owner/Admin/Volunteer）")

      update(:revoke_invitation, :revoke, description: "撤销邀请（邀请人本人或 Owner/Admin 或平台管理员）")
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:access)
    label_field(:target_email)

    table_columns([
      :id,
      :workspace_id,
      :target_email,
      :inviter_id,
      :status,
      :expires_at,
      :inserted_at
    ])
  end
end
