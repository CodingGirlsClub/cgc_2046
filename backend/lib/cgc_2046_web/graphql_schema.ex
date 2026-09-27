defmodule Cgc2046Web.GraphqlSchema do
  use Absinthe.Schema
  import_types(Cgc2046Web.GraphqlSchema.Recruitment)
  import_types(Cgc2046Web.GraphqlSchema.SpeakerInvitation)
  import_types(Cgc2046Web.GraphqlSchema.PaymentOperations)
  import_types(Cgc2046Web.GraphqlSchema.Offering)
  import_types(Cgc2046Web.GraphqlSchema.Learning)
  import_types(Cgc2046Web.GraphqlSchema.Auth)
  import_types(Cgc2046Web.GraphqlSchema.AdminDashboard)
  import_types(Cgc2046Web.GraphqlSchema.Flashback)

  require Ash.Query
  require Ash.Expr

  alias Cgc2046.AdminList
  import Cgc2046Web.GraphqlSchema.Helpers

  use AshGraphql,
    domains: [
      Cgc2046.Admission,
      Cgc2046.Courses,
      Cgc2046.Curriculum,
      Cgc2046.Events,
      Cgc2046.Flashback,
      Cgc2046.Accounts,
      Cgc2046.Learning,
      Cgc2046.Payments,
      Cgc2046.Reconciliation,
      Cgc2046.Recruitment,
      Cgc2046.Sponsorship,
      Cgc2046.Workflows
    ],
    generate_sdl_file: "priv/graphql/schema.graphql",
    auto_generate_sdl_file?: true

  query do
    @desc "Placeholder query until the first resource is added"
    field :ping, :string do
      resolve(fn _, _, _ ->
        {:ok, "pong"}
      end)
    end

    @desc "角色权限矩阵（#66 Rbac）：五角色 × 八能力，对齐前端权限表（需登录；#1 能力接口：abilities 为通用列表）"
    field :permission_matrix, :permission_matrix_payload do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn _actor ->
          roles =
            Cgc2046.Accounts.Rbac.matrix()
            |> Enum.map(fn row ->
              %{
                name: to_string(row.role),
                abilities:
                  Enum.map(row.abilities, fn {name, allowed} ->
                    %{name: to_string(name), allowed: allowed}
                  end)
              }
            end)

          {:ok, %{roles: roles}}
        end)
      end)
    end

    field :offering_readiness, :offering_readiness_payload do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          resolve_readiness(id, actor)
        end)
      end)
    end

    @desc "当前登录用户个人资料（#68 Profile API，需登录）：id/email/displayName/isPlatformAdmin + memberNumber/joinedAt（ADR-0004 收窄为全局身份）"
    field :me, :user do
      resolve(fn _, _, %{context: context} ->
        with_actor(
          context,
          fn actor ->
            load_profile(actor, actor, context, nil)
          end,
          on_nil: fn _ctx ->
            # #13 Finding A：token 签名有效但 user 加载失败（DB 故障 / 撤销）时
            # AuthPlug.load_actor 已标记 cgc_auth_uncertain。返回 auth_uncertain
            # 让前端保持登录态重试，而非误踢已登录用户。
            if context[:cgc_auth_uncertain] do
              {:error, message: "Auth state uncertain", code: "auth_uncertain"}
            else
              {:error, unauthorized_error()}
            end
          end
        )
      end)
    end

    @desc "当前登录用户的掩码手机号（仅本人；未绑定返回 null；前 6 后 4 中间 ****，明文不出 GraphQL 面）"
    field :my_phone, :string do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          {:ok, Cgc2046.Accounts.PhoneNumber.mask(actor.phone)}
        end)
      end)
    end

    @desc "当前用户在某工作台的公开资料（ADR-0004 per-workspace；按 visibility 授权）"
    field :workspace_profile, :workspace_profile do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Accounts.WorkspaceProfile
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(user_id == ^actor.id)
          |> Ash.read_one(tenant: workspace_id, actor: actor)
        end)
      end)
    end

    @desc "当前用户在某工作台的作品集条目列表（ADR-0004 per-workspace）"
    field :my_workspace_portfolio, list_of(:portfolio_item) do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          Ash.read(Cgc2046.Accounts.PortfolioItem,
            action: :my_portfolio,
            tenant: workspace_id,
            actor: actor
          )
        end)
      end)
    end

    @desc "当前用户的 MCP 连接 token 列表（切片 D #44；不含明文，新→旧；policy 仅见本人）"
    field :my_mcp_tokens, list_of(:mcp_token) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Mcp.Token.list_for(actor)
        end)
      end)
    end

    @desc "当前用户作为 Owner/Admin 的跨工作台待审批项（Enrollment + JoinRequest + Sponsorship）；include_expired=true 时附带已过期行（只读展示，E-8 #123）"
    field :my_pending_approvals, non_null(list_of(non_null(:pending_approval))) do
      arg(:include_expired, :boolean)

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.PendingApprovals.list(actor,
            include_expired: args[:include_expired] || false
          )
        end)
      end)
    end

    @desc "当前用户作为 Owner/Admin 的跨工作台可操作待办总数（Enrollment + JoinRequest + Sponsorship 的 pending 且未过审批截止）；已过期不计（KTD8 口径，与 /approvals 展示含过期行存在有意差异）"
    field :pending_approvals_count, non_null(:integer) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.PendingApprovals.count_pending(actor) do
            {:ok, count} -> {:ok, count}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)
    end

    @desc "公开 Initiative 活动页投影；匿名可读，统一跨租户计数口径"
    field :public_initiative, :public_initiative do
      arg(:slug, non_null(:string))

      resolve(fn _, %{slug: slug}, _ ->
        case Cgc2046.Initiatives.Public.get_by_slug(slug) do
          {:ok, payload} -> {:ok, payload}
          {:error, :not_found} -> {:ok, nil}
          {:error, _} -> {:error, [message: "failed to load public initiative", code: "invalid"]}
        end
      end)
    end

    @desc "公开 Initiative 列表；匿名可读"
    field :public_initiatives, non_null(list_of(non_null(:public_initiative_card))) do
      resolve(fn _, _, _ ->
        case Cgc2046.Initiatives.Public.list() do
          {:ok, rows} -> {:ok, rows}
          {:error, _} -> {:error, [message: "failed to load public initiatives", code: "invalid"]}
        end
      end)
    end

    import_fields(:flashback_queries)
    @desc "平台管理员：脱敏 workflow 运行元数据（不含 facts/input snapshot）"
    field :platform_workflow_audit, non_null(list_of(non_null(:platform_workflow_audit))) do
      arg(:workspace_id, :id)
      arg(:status, :string)
      arg(:started_after, :datetime)
      arg(:started_before, :datetime)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          {:ok,
           Cgc2046.Workflows.PlatformAudit.list(
             workspace_id: args[:workspace_id],
             status: args[:status],
             started_after: args[:started_after],
             started_before: args[:started_before]
           )}
        end)
      end)
    end

    @desc "当前用户在某工作台的 MCP 工具调用活动流（plan 020 U2.1；policy：workspace 成员 + 仅本人；params 摘要级不返回）"
    field :my_workspace_tool_calls, non_null(list_of(non_null(:workspace_tool_call))) do
      arg(:workspace_id, non_null(:id))
      arg(:first, :integer)

      resolve(fn _, args, %{context: context} ->
        # args 只含调用方提供的键（first 可缺省）——不能用固定键 pattern match。
        # 018：first 封顶（与 AdminList.paginate 共用上限），防无界全表导出
        with_actor(context, fn actor ->
          resolve_my_workspace_tool_calls(
            actor,
            args[:workspace_id],
            min(args[:first] || 50, AdminList.max_first())
          )
        end)
      end)
    end

    import_fields(:speaker_invitation_queries)

    import_fields(:admin_dashboard_queries)
    @desc "当前用户（申请人）的工作台创建申请列表（R7a；任何人可见自己的申请）"
    field :my_workspace_applications, non_null(list_of(non_null(:admin_workspace_application))) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Accounts.WorkspaceApplication
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(applicant_id == ^actor.id)
          |> Ash.read(actor: actor)
          |> map_error(context, :read, Cgc2046.Accounts.WorkspaceApplication, Cgc2046.Accounts)
        end)
      end)
    end

    import_fields(:offering_queries)

    import_fields(:recruitment_queries)
    import_fields(:learning_queries)
  end

  mutation do
    import_fields(:auth_mutations)
    @desc "Owner/Admin 创建一次性工作台邀请小程序码"
    field :generate_mini_program_code, :miniprogram_code_result do
      arg(:workspace_id, non_null(:id))
      arg(:platform, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:workspace_id])

      resolve(fn _, %{workspace_id: workspace_id, platform: platform}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Accounts.MiniprogramCode.generate(workspace_id, actor, platform) do
            {:ok, result} ->
              {:ok, result}

            {:error, :forbidden} ->
              {:error, message: "Forbidden", code: "forbidden"}

            {:error, :invalid_platform} ->
              {:error, message: "Invalid platform", code: "invalid_platform"}

            {:error, :daily_quota_exhausted} ->
              {:error, message: "Daily quota exhausted", code: "daily_quota_exhausted"}

            # 锁超时/死锁（#621）：BusinessError 原样出面（message 逐字 + 独立 code），
            # 不落下面 code_generation_failed 兜底——可自愈并发冲突不是"生成失败"。
            {:error, %Cgc2046.Errors.BusinessError{code: code, message: message}} ->
              {:error, message: message, code: code}

            {:error, _} ->
              {:error, message: "Code generation failed", code: "code_generation_failed"}
          end
        end)
      end)
    end

    @desc "使用一次性小程序 scene 接受工作台邀请"
    field :admit_member_by_token, :invitation do
      arg(:scene, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:scene])

      resolve(fn _, %{scene: scene}, %{context: context} ->
        cond do
          is_nil(context[:actor]) ->
            {:error, unauthorized_error()}

          not Cgc2046.Accounts.MiniprogramCode.valid_scene?(scene) ->
            {:error, message: "Invalid scene", code: "invalid_scene"}

          true ->
            actor = context[:actor]

            # #217 旁路读取（A 类·凭证即凭据）：一次性小程序 scene 码经
            # code_for_scene 校验（scene + 未过期精确匹配）换得 invitation_id，
            # Ash.get 直读定位（Invitation read policy 是 inviter/Owner-Admin
            # 视角，受邀者被拒成 not_found 到不了 action）；随后 for_update 带
            # actor 走 accept_miniprogram 的 actor_present 门禁，before_action
            # scene 复验（已用/过期 → invalid_or_expired_scene）。
            with {:ok, code} <- Cgc2046.Accounts.MiniprogramCode.code_for_scene(scene),
                 {:ok, invitation} <-
                   Ash.get(Cgc2046.Accounts.Invitation, code.invitation_id, authorize?: false),
                 {:ok, accepted} <-
                   invitation
                   |> Ash.Changeset.for_update(:accept_miniprogram, %{scene: scene})
                   |> Ash.update(actor: actor) do
              {:ok, accepted}
            else
              {:error, :invalid_scene} ->
                {:error, message: "Invalid scene", code: "invalid_scene"}

              {:error, :invalid_or_expired_scene} ->
                {:error,
                 message: "Invitation has already been used or scene has expired",
                 code: "invalid_or_expired_scene"}

              {:error, error} ->
                {:error,
                 to_ash_graphql_errors(
                   error,
                   context,
                   :accept_miniprogram,
                   Cgc2046.Accounts.Invitation
                 )}
            end
        end
      end)
    end

    @desc "接受邀请→建 Membership + 预授权角色入座（#96：手写 resolver 绕过 read policy 记录加载）"
    field :accept_invitation, :accept_invitation_result do
      arg(:id, non_null(:id))
      arg(:input, non_null(:accept_invitation_input))

      # 手写 field 不经过 middleware/3 回调（那是 AshGraphql 自动 mutation 的接线），
      # 与 admit_member_by_token 一致显式挂载；限流 key 与自动 mutation 相同（input.token）。
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:input, :token])

      resolve(fn _, %{id: id, input: %{token: token}}, %{context: context} ->
        with_actor(context, fn actor ->
          # #96：AshGraphql update mutation 的 read-before-write 用 :read action 加载记录
          # （read policy 下推成 inviter_id == actor.id），受邀者被拒成 not_found，到不了
          # accept action。这里改为 id + token_hash 双因子定位 + authorize?: false 加载：
          # 两个条件都匹配才放行（token 是凭证，与 validateInvitation 信息面一致），
          # 不匹配返回 not_found，不泄露邀请存在性。accept action 的
          # authorize_if(actor_present()) 与 before_action token 复验仍完整生效。
          # TokenCredential.fetch 以 extra_filter: [id: id] 保留双因子，nil 塌缩为
          # :invalid_token，由调用方映射回 accept_not_found_errors（not_found 语义）。
          with {:ok, invitation} <-
                 Cgc2046.Accounts.TokenCredential.fetch(Cgc2046.Accounts.Invitation, token,
                   id: id
                 ),
               {:ok, accepted} <-
                 invitation
                 |> Ash.Changeset.for_update(:accept, %{token: token})
                 |> Ash.update(actor: actor) do
            {:ok, %{result: accepted, errors: []}}
          else
            {:error, :invalid_token} ->
              {:ok, %{result: nil, errors: accept_not_found_errors(context, id)}}

            {:error, error} ->
              {:ok,
               %{
                 result: nil,
                 errors:
                   to_ash_graphql_errors(
                     error,
                     context,
                     :accept,
                     Cgc2046.Accounts.Invitation
                   )
               }}
          end
        end)
      end)
    end

    @desc "记录一次小程序订阅消息授权并增加一个可用次数"
    field :grant_mini_program_notification_consent, :integer do
      arg(:platform, non_null(:string))
      arg(:template_key, non_null(:string))

      # #930：与登录拆桶——grant 本来就要求登录，按账号计（原「IP + 平台」桶与登录共用，
      # 1 次登录 + 1 次三模板订阅就吃掉 4/5，再登录即 Too many requests）
      resolve(fn _, %{platform: platform, template_key: template_key}, %{context: context} ->
        with_actor(context, fn actor ->
          key = Cgc2046Web.Plugs.RateLimit.build_key("rate:notification-consent:actor", actor.id)

          with :ok <- Cgc2046Web.Plugs.RateLimit.check(key, limit: :notification_consent_actor),
               {:ok, remaining} <-
                 Cgc2046.Notifications.Consent.grant(actor.id, platform, template_key) do
            {:ok, remaining}
          else
            :error ->
              {:error, message: "Too many requests. Try again later.", code: "rate_limited"}

            {:error, :invalid_platform} ->
              {:error, message: "Invalid platform", code: "invalid_platform"}

            {:error, _} ->
              {:error, message: "Consent grant failed", code: "consent_grant_failed"}
          end
        end)
      end)
    end

    @desc "更新当前用户全局显示名（ADR-0004：displayName 保留全局身份字段）"
    field :update_display_name, :user do
      arg(:display_name, non_null(:string))

      resolve(fn _, %{display_name: display_name}, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.update(actor, %{display_name: display_name},
                 action: :update_display_name,
                 actor: actor
               ) do
            {:ok, user} ->
              # member_number/joined_at 为计算属性，返回前需显式加载
              load_profile(user, actor, context, :update_display_name)

            {:error, error} ->
              {:error, to_ash_graphql_errors(error, context, :update_display_name)}
          end
        end)
      end)
    end

    @desc "绑定/换绑当前用户手机号（验证码 purpose=CHANGE_PHONE 验新号；仅本人；目标号已被他人占用即拒绝，不做自助合并）"
    field :update_my_phone, :user do
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      resolve(fn _, %{phone: raw_phone, code: code}, %{context: context} ->
        with_actor(context, fn actor ->
          with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
               :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_verify_limits(context, phone),
               :ok <-
                 Cgc2046.Accounts.PhoneVerificationCode.consume_valid(phone, code, :change_phone) do
            Cgc2046.Accounts.WebAuthFlow.update_my_phone(actor, phone, context)
          else
            {:error, :invalid} ->
              {:error, message: "Invalid phone number", code: "invalid_phone"}

            {:error, :rate_limited} ->
              {:error, message: "Too many requests. Try again later.", code: "rate_limited"}

            {:error, :invalid_code} ->
              {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

            {:error, :code_not_available} ->
              {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}
          end
        end)
      end)
    end

    @desc "更新当前用户界面语言偏好（i18n Phase 1；zh-CN | en，仅本人）"
    field :update_my_locale, :user do
      arg(:locale, non_null(:string))

      resolve(fn _, %{locale: locale}, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.update(actor, %{locale: locale},
                 action: :update_locale,
                 actor: actor
               ) do
            {:ok, user} ->
              load_profile(user, actor, context, :update_locale)

            {:error, error} ->
              {:error, to_ash_graphql_errors(error, context, :update_locale)}
          end
        end)
      end)
    end

    @desc "拒绝首公里接入邀请（每次登录弹直到明确拒绝；幂等保留首次拒绝时间戳，仅本人）"
    field :dismiss_onboarding_invitation, :user do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.update(actor, %{},
                 action: :dismiss_onboarding_invitation,
                 actor: actor
               ) do
            {:ok, user} ->
              load_profile(user, actor, context, :dismiss_onboarding_invitation)

            {:error, error} ->
              {:error, to_ash_graphql_errors(error, context, :dismiss_onboarding_invitation)}
          end
        end)
      end)
    end

    @desc "更新当前用户在某工作台的资料（ADR-0004 per-workspace）"
    field :update_workspace_profile, :workspace_profile do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:update_workspace_profile_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          scoped_update(
            actor,
            Cgc2046.Accounts.WorkspaceProfile,
            workspace_id,
            :update_profile,
            map_input(input),
            context
          )
        end)
      end)
    end

    @desc "设置当前用户在某工作台的 UI 主题偏好（ADR-0004 per-workspace）"
    field :set_workspace_theme, :workspace_profile do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:set_workspace_theme_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          scoped_update(
            actor,
            Cgc2046.Accounts.WorkspaceProfile,
            workspace_id,
            :set_ui_theme,
            %{ui_theme_preference: input.ui_theme_preference},
            context
          )
        end)
      end)
    end

    @desc "在某工作台创建作品集条目（ADR-0004；workspace_id 与 user_id 自动填充，防跨租户伪造）"
    field :create_portfolio_item, :portfolio_item do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:create_portfolio_item_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          attrs = map_input(input, [:title, :description, :url, :icon])

          Cgc2046.Accounts.PortfolioItem
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create(tenant: workspace_id, actor: actor)
        end)
      end)
    end

    @desc "更新某工作台自己的作品集条目（ADR-0004；tenant 隔离）"
    field :update_portfolio_item, :portfolio_item do
      arg(:id, non_null(:id))
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:update_portfolio_item_input))

      resolve(fn _, %{id: id, workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          attrs = map_input(input, [:title, :description, :url, :icon])

          with {:ok, item} <-
                 Cgc2046.Accounts.PortfolioItem
                 |> Ash.get(id, tenant: workspace_id, actor: actor) do
            item
            |> Ash.Changeset.for_update(:update, attrs)
            |> Ash.update(tenant: workspace_id, actor: actor)
          end
        end)
      end)
    end

    @desc "删除某工作台自己的作品集条目（ADR-0004；tenant 隔离）"
    field :delete_portfolio_item, :portfolio_item do
      arg(:id, non_null(:id))
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{id: id, workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          with {:ok, item} <-
                 Cgc2046.Accounts.PortfolioItem
                 |> Ash.get(id, tenant: workspace_id, actor: actor) do
            case Ash.destroy(item, tenant: workspace_id, actor: actor) do
              :ok -> {:ok, item}
              {:error, error} -> {:error, error}
            end
          end
        end)
      end)
    end

    @desc "签发 MCP 连接 token（切片 D #44；明文仅本次经 plainToken 返回一次，库中只存 SHA256 hash）"
    field :create_mcp_token, :create_mcp_token_payload do
      arg(:name, non_null(:string))

      resolve(fn _, %{name: name}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Mcp.Token.issue(name, actor) do
            {:ok, token, plain} ->
              {:ok, %{result: token, plain_token: plain, errors: []}}

            {:error, error} ->
              {:ok,
               %{
                 result: nil,
                 plain_token: nil,
                 errors:
                   to_ash_graphql_errors(error, context, :issue, Cgc2046.Mcp.Token, Cgc2046.Mcp)
               }}
          end
        end)
      end)
    end

    @desc "撤销 MCP 连接 token（切片 D #44；仅本人，置 revokedAt 保留审计行；他人 token 一律 not_found 不泄露存在性）"
    field :revoke_mcp_token, :mcp_token do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Mcp.Token.revoke(id, actor) do
            {:ok, revoked} ->
              {:ok, revoked}

            {:error, :not_found} ->
              # NotFound（他人 token / 不存在 id）统一塌缩，不泄露存在性。
              # 与 invalid 分支同经 AshGraphql 序列化（message/code/fields 齐备），
              # 恢复 AshGraphql 原行为的 error 结构（message "could not be found"、
              # fields ["id"]）。
              {:error,
               to_ash_graphql_errors(
                 Ash.Error.Query.NotFound.exception(
                   primary_key: %{id: id},
                   resource: Cgc2046.Mcp.Token
                 ),
                 context,
                 :revoke,
                 Cgc2046.Mcp.Token,
                 Cgc2046.Mcp
               )}

            {:error, {:invalid, error}} ->
              {:error,
               to_ash_graphql_errors(error, context, :revoke, Cgc2046.Mcp.Token, Cgc2046.Mcp)}
          end
        end)
      end)
    end

    import_fields(:payment_operation_mutations)

    import_fields(:speaker_invitation_mutations)

    import_fields(:admin_dashboard_mutations)

    import_fields(:offering_mutations)

    import_fields(:flashback_mutations)
    import_fields(:flashback_wish_mutations)
    import_fields(:recruitment_mutations)
  end

  # ── RBAC 类型（#66 角色权限矩阵；原 rbac_types.ex 内联，唯一消费者为本 schema） ──

  object :ability_grant do
    field(:name, non_null(:string),
      description:
        "能力名：view_workspace / access_invite_only / list_members / manage_members / assign_roles / create_workspace"
    )

    field(:allowed, non_null(:boolean))
  end

  object :permission_matrix_row do
    field(:name, non_null(:string),
      description: "角色名：owner / admin / tutor / volunteer / learner"
    )

    field(:abilities, non_null(list_of(non_null(:ability_grant))))
  end

  object :permission_matrix_payload do
    field(:roles, non_null(list_of(non_null(:permission_matrix_row))))
  end

  object :offering_readiness_payload do
    field(:ready, non_null(:boolean))
    field(:items, non_null(list_of(non_null(:offering_readiness_item))))
  end

  object :offering_readiness_item do
    field(:key, non_null(:string))
    field(:label, non_null(:string))
    field(:ok, non_null(:boolean))
  end

  object :pending_approval do
    field(:id, non_null(:id))
    field(:kind, non_null(:string))
    field(:workspace_id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:event_id, :id)
    field(:course_id, :id)
    field(:status, non_null(:string))
    field(:approval_deadline, :datetime)
    field(:expired_at, :datetime)
    field(:requester_name, :string)
    field(:workspace_name, :string)
    field(:context_title, :string)

    # E-9 #123 expired 重提链接落点字段（workspace_slug 全 kind；event_slug
    # 仅 sponsorship event 级行非空，可空供给物无 slug）
    field(:workspace_slug, :string)
    field(:event_slug, :string)

    # E-3 #48 sponsorship 行（其他 kind 为 null）
    field(:level, :string)
    field(:company_name, :string)
    field(:contact_email, :string)
    field(:tier_name, :string)
    field(:amount, :integer)
  end

  object :platform_workflow_audit do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:definition_type, non_null(:string))
    field(:status, non_null(:string))
    field(:started_at, :datetime)
    field(:finished_at, :datetime)
    field(:inserted_at, non_null(:datetime))
    field(:error_summary, :string)
  end

  object :workspace_tool_call do
    field(:id, non_null(:id))
    field(:tool, non_null(:string))
    field(:status, non_null(:string))
    field(:latency_ms, :integer)
    field(:inserted_at, non_null(:datetime))
    field(:error_message, :string)
  end

  object :miniprogram_code_result do
    field(:invitation_id, non_null(:id))
    field(:platform, non_null(:string))
    field(:scene, non_null(:string))
    field(:code_base64, non_null(:string))
    field(:expires_at, non_null(:datetime))
  end

  # 持 token 的邀请接口限流：validate/accept 均吃明文 token 参数，按 IP+token 计，
  # 5 次/15 分钟（复用 RateLimit plug，与 sign_in/sign_up 同档位）。
  # token 为 256-bit 强随机，枚举不成立；此为已知 token 被滥用探测时的加固。
  # arity-3：Absinthe 的 middleware callback 是 arity-3（schema.middleware(mw, field, object)），
  # arity-2 不会被框架调用。
  def middleware(middleware, %{identifier: :validate_invitation}, _object),
    do: [{Cgc2046Web.Plugs.RateLimit, key_path: [:token]} | middleware]

  # 注：accept_invitation 现为手写 field，RateLimit 在 field 内显式挂载
  # （手写 field 不经过 middleware/3 回调），不再需要此处的 identifier 分支。

  def middleware(middleware, _field, _object), do: middleware

  # ── 个人资料相关类型（ADR-0004 per-workspace）────────────────────────

  object :workspace_profile do
    @desc "per-workspace 成员公开资料（ADR-0004）"
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:avatar_url, :string)
    field(:location, :string)
    field(:about, :string)
    field(:skills, list_of(:string))
    field(:visibility, :string)
    field(:ui_theme_preference, non_null(:string))
  end

  object :portfolio_item do
    @desc "per-workspace 作品集条目（ADR-0004）"
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    field(:description, :string)
    field(:url, :string)
    field(:icon, non_null(:string))
  end

  input_object :update_workspace_profile_input do
    @desc "updateWorkspaceProfile 输入（ADR-0004）：avatarUrl/location/about/skills/visibility 可选"
    field(:avatar_url, :string)
    field(:location, :string)
    field(:about, :string)
    field(:skills, list_of(:string))
    field(:visibility, :string)
  end

  input_object :set_workspace_theme_input do
    @desc "setWorkspaceTheme 输入：uiThemePreference 必填，仅 dark | light"
    field(:ui_theme_preference, non_null(:string))
  end

  input_object :create_portfolio_item_input do
    @desc "createPortfolioItem 输入：title 必填，description/url/icon 可选"
    field(:title, non_null(:string))
    field(:description, :string)
    field(:url, :string)
    field(:icon, :string)
  end

  input_object :update_portfolio_item_input do
    @desc "updatePortfolioItem 输入：title/description/url/icon 可选"
    field(:title, :string)
    field(:description, :string)
    field(:url, :string)
    field(:icon, :string)
  end

  # ── MCP 连接 token（切片 D #44；手写三入口，资源不经 AshGraphql 自动暴露）──

  object :mcp_token do
    @desc "MCP 连接 token（明文不可经此类型读回；hash 不落 GraphQL 面）"
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:last_used_at, :datetime)
    field(:revoked_at, :datetime)
    field(:inserted_at, non_null(:datetime))
  end

  object :create_mcp_token_payload do
    @desc "createMcpToken 返回：result 为 token 记录；plainToken 明文仅此一次"
    field(:result, :mcp_token)
    field(:plain_token, :string)
    field(:errors, list_of(:mutation_error))
  end

  # acceptInvitation 手写 resolver 的类型（#96）：与自动生成的同名同形，
  # API 形态不变（acceptInvitation(id: ID!, input: AcceptInvitationInput!): AcceptInvitationResult!）。
  input_object :accept_invitation_input do
    @desc "acceptInvitation 输入：token 为明文邀请令牌（accept 须复验）"
    field(:token, non_null(:string))
  end

  object :accept_invitation_result do
    @desc "acceptInvitation 返回：result 为已接受邀请记录；errors 为业务错误"
    field(:result, :invitation)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  # acceptInvitation 的 not_found：id+token 双因子不匹配时返回，与 AshGraphql 自动 mutation
  # 的 NotFound 映射一致（message "could not be found" / code "not_found"），复用同一序列化路径。
  defp accept_not_found_errors(context, id) do
    error =
      Ash.Error.Query.NotFound.exception(
        primary_key: %{id: id},
        resource: Cgc2046.Accounts.Invitation
      )

    to_ash_graphql_errors(error, context, :accept, Cgc2046.Accounts.Invitation)
  end

  # 统一的个人资料加载：member_number/joined_at 为计算属性，获取与更新后均需显式加载。
  # 加载失败（罕见：calculation/DB 异常）经 to_ash_graphql_errors 映射，与
  # update_profile/set_ui_theme 同源——避免把 Ash 内部 stacktrace 当 string 返给客户端。
  # `action` 用于错误路径解析（与出错 mutation 的 action 对齐，nil 表示 query 侧 me）。
  defp load_profile(user, actor, context, action) do
    case Ash.load(user, [:member_number, :joined_at],
           actor: actor,
           domain: Cgc2046.Accounts
         ) do
      {:ok, loaded} ->
        {:ok, loaded}

      {:error, error} ->
        {:error, to_ash_graphql_errors(error, context, action)}
    end
  end

  # owner 域 read-first update 组合子（PR-E D5）：filter(user_id == ^actor.id) +
  # read_one(tenant:, actor:) → {:ok, nil} 分支错误单点（workspace_profile_not_found）
  # → for_update(action, attrs) → Ash.update(tenant:, actor:)。错误路径经
  # to_ash_graphql_errors 显式透传 resource（message/code/fields 逐字保留）。
  # 消费方：update_workspace_profile(:update_profile, map_input 全量) /
  # set_workspace_theme(:set_ui_theme, 单字段)。
  defp scoped_update(actor, resource, tenant_id, action, attrs, context) do
    case resource
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(user_id == ^actor.id)
         |> Ash.read_one(tenant: tenant_id, actor: actor) do
      {:ok, nil} ->
        {:error,
         message: "Workspace profile not found or not accessible",
         code: "workspace_profile_not_found"}

      {:ok, profile} ->
        profile
        |> Ash.Changeset.for_update(action, attrs)
        |> Ash.update(tenant: tenant_id, actor: actor)

      {:error, error} ->
        {:error, to_ash_graphql_errors(error, context, action, resource)}
    end
  end

  object :admin_workspace_application do
    field(:id, non_null(:id))
    field(:applicant_id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:purpose, non_null(:string))
    field(:status, non_null(:string))
    field(:rejection_reason, :string)
    # #116 R10a：处理人/时间（approve/reject 对称四字段；pending/expired 为 null）
    field(:approved_by, :id)
    field(:approved_at, :datetime)
    field(:rejected_by, :id)
    field(:rejected_at, :datetime)
    field(:inserted_at, non_null(:datetime))
  end

  object :public_initiative do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
    field(:status, non_null(:string))
    field(:city_count, non_null(:integer))
    field(:event_count, non_null(:integer))
    field(:confirmed_count, non_null(:integer))
    field(:qualified_event_count, non_null(:integer))
    field(:cities, non_null(list_of(non_null(:public_initiative_city))))
  end

  object :public_initiative_card do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
    field(:status, non_null(:string))
  end

  object :public_initiative_city do
    field(:city, non_null(:string))
    field(:events, non_null(list_of(non_null(:public_initiative_event))))
  end

  object :public_initiative_event do
    field(:id, non_null(:id))
    field(:slug, non_null(:string))
    field(:title, non_null(:string))
    field(:status, non_null(:string))
    field(:visibility, non_null(:string))
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:registration_deadline, :datetime)
    field(:venue, :json_string)
    field(:confirmed_count, non_null(:integer))
    field(:min_participants, :integer)
    field(:qualification_status, :string)
    field(:archived, non_null(:boolean))
    field(:qualification_badge, non_null(:string))
    field(:short_by, :integer)

    # 参与条件披露（#627）：缴费槽三态 + 押金明细 + 年龄门槛存在性 + 收费金额锚。
    # 全部来自 Event 已物化快照列（`Initiatives.Public` 的裸 SQL 投影），不暴露规则表。
    field(:payment_mode, non_null(:string))
    field(:deposit, non_null(:public_initiative_deposit))
    field(:min_age, :integer)
    field(:price_range_min_cents, :integer)
  end

  @desc "公开页押金明细（#627）：金额缺失/非正时 amountCents 为 null，enabled 仍 true——绝不显示 ¥0"
  object :public_initiative_deposit do
    field(:enabled, non_null(:boolean))
    field(:amount_cents, :integer)
    field(:refundable_on_check_in, :boolean)
  end

  # plan 020 U2.1：本人 MCP 工具调用活动流。
  # policy（显式判定，与 Wrapper 成员门槛同源）：workspace 成员 + 仅本人。
  # 过滤：params JSONB 内 workspace_id（键名 params["workspace_id"]，Wrapper 落库
  # 格式，assumption 1）+ user_id == actor.id；排序 inserted_at desc + id desc。
  # 非成员统一 forbidden；读取经 authorize?: false 直读（ToolCallLog 读 policy 仍
  # platform_admin 专属，本查询按成员+本人独立门控，params 摘要级不返回）。
  defp resolve_my_workspace_tool_calls(actor, workspace_id, first) do
    if Cgc2046.Accounts.MembershipContext.membership_of(actor, workspace_id) do
      ws_id = to_string(workspace_id)

      query =
        Cgc2046.Mcp.ToolCallLog
        |> Ash.Query.filter(user_id == ^actor.id)
        |> Ash.Query.filter(fragment("params->>'workspace_id' = ?", ^ws_id))
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(first)

      case Ash.read(query, authorize?: false) do
        {:ok, logs} ->
          {:ok,
           Enum.map(logs, fn log ->
             %{
               id: log.id,
               tool: log.tool,
               status: to_string(log.result_status),
               latency_ms: log.latency_ms,
               inserted_at: log.inserted_at,
               error_message: log.error_message
             }
           end)}

        {:error, error} ->
          {:error, to_ash_graphql_errors(error, %{}, :read, Cgc2046.Mcp.ToolCallLog, Cgc2046.Mcp)}
      end
    else
      {:error, [message: "forbidden", code: "forbidden"]}
    end
  end

  defp resolve_readiness(id, actor) do
    with {:ok, entity} <- fetch_offering_by_id(id, actor) do
      {:ok, Cgc2046.Offering.Readiness.evaluate(entity)}
    end
  end

  # offeringReadiness 目标可能是 Event 或 Course（原 event 优先、失败回退 course）。
  # 读取唯一真源 = Offering；**必须显式 authorize?: true**（D2 风险：Offering 默认
  # authorize?: false 会绕过 read policy，actor 感知读取退化为全量可见）。
  defp fetch_offering_by_id(id, actor) do
    case Cgc2046.Offering.fetch(:event, id, actor: actor, authorize?: true) do
      {:ok, entity} -> {:ok, entity}
      {:error, _} -> Cgc2046.Offering.fetch(:course, id, actor: actor, authorize?: true)
    end
  end
end
