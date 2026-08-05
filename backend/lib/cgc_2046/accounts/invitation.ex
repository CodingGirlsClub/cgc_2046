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
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  require Ash.Query

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

    # 工作台预览字段（决策 8）：内部 authorize?: false 读 workspace，绕过 read policy。
    # 供受邀人在 invite_only 场景下无需读 workspace 即可看到要加入哪个工作台。
    calculate(:workspace_name, :string,
      public?: true,
      calculation: fn invitations, _opts ->
        Enum.map(invitations, fn invitation ->
          if invitation.workspace_id do
            workspace =
              Ash.get!(Cgc2046.Accounts.Workspace, invitation.workspace_id, authorize?: false)

            workspace.name
          else
            nil
          end
        end)
      end
    )

    calculate(:workspace_slug, :string,
      public?: true,
      calculation: fn invitations, _opts ->
        Enum.map(invitations, fn invitation ->
          if invitation.workspace_id do
            workspace =
              Ash.get!(Cgc2046.Accounts.Workspace, invitation.workspace_id, authorize?: false)

            workspace.slug
          else
            nil
          end
        end)
      end
    )

    calculate(:workspace_join_policy, :string,
      public?: true,
      calculation: fn invitations, _opts ->
        Enum.map(invitations, fn invitation ->
          if invitation.workspace_id do
            workspace =
              Ash.get!(Cgc2046.Accounts.Workspace, invitation.workspace_id, authorize?: false)

            to_string(workspace.join_policy)
          else
            nil
          end
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

  # 过期判定改为读时计算（effective_status），不再在 read 时执行 UPDATE。
  # TODO: 引入 Quantum/Oban 定时器后改为主动落库过期，effective_status 作为兜底。

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
      description("撤销邀请（邀请人本人或 Owner/Admin）")
      require_atomic?(false)

      change(set_attribute(:status, :revoked))
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

      # 复验 token + 校验邀请状态（before_action 重新加载记录以确保最新状态）
      # token 校验先于状态校验：不匹配直接拒，不泄露 used/revoked/expired 状态信息
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          invitation = Ash.get!(Cgc2046.Accounts.Invitation, cs.data.id, authorize?: false)

          token = Ash.Changeset.get_argument(cs, :token)
          token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

          if invitation.token_hash != token_hash do
            cs
            |> Ash.Changeset.add_error(
              Ash.Error.Changes.InvalidAttribute.exception(
                field: :token,
                message: "Invalid invitation token"
              )
            )
          else
            cond do
              invitation.status == :used ->
                cs
                |> Ash.Changeset.add_error(
                  Ash.Error.Changes.InvalidAttribute.exception(
                    field: :status,
                    message: "Invitation has already been used"
                  )
                )

              invitation.status == :revoked ->
                cs
                |> Ash.Changeset.add_error(
                  Ash.Error.Changes.InvalidAttribute.exception(
                    field: :status,
                    message: "Invitation has been revoked"
                  )
                )

              invitation.expires_at &&
                  DateTime.compare(invitation.expires_at, DateTime.utc_now()) == :lt ->
                cs
                |> Ash.Changeset.add_error(
                  Ash.Error.Changes.InvalidAttribute.exception(
                    field: :expires_at,
                    message: "Invitation has expired"
                  )
                )

              true ->
                cs
            end
          end
        end)
      end)

      # 设置状态为 used
      change(set_attribute(:status, :used))
      change(set_attribute(:accepted_at, DateTime.utc_now()))

      # 设置 accepted_by（before_action + force_change_attribute 绕过已校验限制）
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          actor = cs.context[:private][:actor]
          Ash.Changeset.force_change_attribute(cs, :accepted_by, actor && actor.id)
        end)
      end)

      # 建 Membership + 预授权角色入座
      change(
        after_action(fn changeset, invitation, _context ->
          actor = changeset.context[:private][:actor]
          tenant = invitation.workspace_id

          # 守卫：受邀人已是该工作台成员时不重复建成员资格（DB 唯一索引兜底，
          # 此处转成带业务语义的错误，避免 generic unique-constraint 上抛）。
          existing =
            Cgc2046.Accounts.WorkspaceMembership
            |> Ash.Query.for_read(:read)
            |> Ash.Query.filter(workspace_id == ^tenant and user_id == ^actor.id)
            |> Ash.read!(tenant: tenant, authorize?: false)

          if existing != [] do
            {:error,
             Ash.Error.Changes.InvalidAttribute.exception(
               field: :user_id,
               message: "你已是该工作台成员"
             )}
          else
            # 建 Membership。并发下两个 accept 可能同时越过上面的 existing 检查，
            # DB unique index (wm_unique_ws_user_idx) 会拒绝第二个；此处把
            # {:error, _} 转成与上面一致的业务错误，避免裸 MatchError 上抛 500。
            case Cgc2046.Accounts.WorkspaceMembership
                 |> Ash.Changeset.for_create(:create, %{user_id: actor.id})
                 |> Ash.create(tenant: tenant, actor: actor, authorize?: false) do
              {:ok, membership} ->
                # 有预授权角色则建 MembershipRole（决策 6）
                if invitation.preauthorized_role_names &&
                     invitation.preauthorized_role_names != [] do
                  roles = Ash.read!(Cgc2046.Accounts.Role, tenant: tenant, authorize?: false)

                  Enum.each(invitation.preauthorized_role_names, fn role_name ->
                    role = Enum.find(roles, &(&1.name == role_name))

                    if role do
                      Ash.create!(
                        Cgc2046.Accounts.MembershipRole,
                        %{
                          membership_id: membership.id,
                          role_id: role.id
                        },
                        tenant: tenant,
                        authorize?: false
                      )
                    end
                  end)
                end

                {:ok, invitation}

              {:error, _} ->
                {:error,
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :user_id,
                   message: "你已是该工作台成员"
                 )}
            end
          end
        end)
      )
    end
  end

  policies do
    # :create 限工作台成员（Owner/Admin/Volunteer），且 inviter_id 必须是 actor 本人。
    # forbid_unless 是守卫语义（不满足即拒绝），不同于 authorize_if 的 OR 短路放行——
    # 若用 authorize_if 加 inviter_id 校验，Volunteer 会被其后的 Volunteer check 放行，
    # inviter_id 校验形同虚设。预授权角色约束由 change 校验。
    policy action(:create) do
      forbid_unless(expr(inviter_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.WorkspaceActorIsVolunteer)
    end

    # :revoke 限邀请人本人或 Owner/Admin
    policy action(:revoke) do
      authorize_if(expr(inviter_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
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

    # :read 邀请人本人可读自己的邀请；Owner/Admin 可读该工作台全部邀请
    policy action_type(:read) do
      authorize_if(expr(inviter_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
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

      update(:revoke_invitation, :revoke, description: "撤销邀请（邀请人本人或 Owner/Admin）")

      update(:accept_invitation, :accept, description: "接受邀请→建 Membership + 预授权角色入座")
    end
  end
end
