defmodule Cgc2046Web.GraphqlSchema do
  use Absinthe.Schema

  require Logger
  require Ash.Query

  use AshGraphql,
    domains: [Cgc2046.Api, Cgc2046.GlobalApi],
    generate_sdl_file: "priv/graphql/schema.graphql",
    auto_generate_sdl_file?: true

  query do
    @desc "Placeholder query until the first resource is added"
    field :ping, :string do
      resolve(fn _, _, _ ->
        {:ok, "pong"}
      end)
    end

    @desc "角色权限矩阵（#66 Rbac）：六角色 × 六能力，对齐前端权限表（需登录；#1 能力接口：abilities 为通用列表）"
    field :permission_matrix, :permission_matrix_payload do
      resolve(fn _, _, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, "unauthorized"}

          _actor ->
            roles =
              Cgc2046.Rbac.matrix()
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
        end
      end)
    end

    @desc "当前登录用户个人资料（#68 Profile API，需登录）：id/email/displayName/isPlatformAdmin + memberNumber/joinedAt（ADR-0004 收窄为全局身份）"
    field :me, :user do
      resolve(fn _, _, %{context: context} ->
        case context[:actor] do
          nil ->
            # #13 Finding A：token 签名有效但 user 加载失败（DB 故障 / 撤销）时
            # AuthPlug.load_actor 已标记 cgc_auth_uncertain。返回 auth_uncertain
            # 让前端保持登录态重试，而非误踢已登录用户。
            if context[:cgc_auth_uncertain] do
              {:error, message: "Auth state uncertain", code: "auth_uncertain"}
            else
              {:error, unauthorized_error()}
            end

          actor ->
            load_profile(actor, actor, context, nil)
        end
      end)
    end

    @desc "当前用户在某工作台的公开资料（ADR-0004 per-workspace；按 visibility 授权）"
    field :workspace_profile, :workspace_profile do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            Cgc2046.Accounts.WorkspaceProfile
            |> Ash.Query.for_read(:read)
            |> Ash.Query.filter(user_id == ^actor.id)
            |> Ash.read_one(tenant: workspace_id, actor: actor)
        end
      end)
    end

    @desc "当前用户在某工作台的作品集条目列表（ADR-0004 per-workspace）"
    field :my_workspace_portfolio, list_of(:portfolio_item) do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            Ash.read(Cgc2046.Accounts.PortfolioItem,
              action: :my_portfolio,
              tenant: workspace_id,
              actor: actor
            )
        end
      end)
    end

    @desc "当前用户的 MCP 连接 token 列表（切片 D #44；不含明文，新→旧；policy 仅见本人）"
    field :my_mcp_tokens, list_of(:mcp_token) do
      resolve(fn _, _, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            Cgc2046.Mcp.Token.list_for(actor)
        end
      end)
    end

    @desc "当前用户作为 Owner/Admin 的跨工作台待审批项（Enrollment + JoinRequest）"
    field :my_pending_approvals, non_null(list_of(non_null(:pending_approval))) do
      resolve(fn _, _, %{context: context} ->
        case context[:actor] do
          nil -> {:error, unauthorized_error()}
          actor -> Cgc2046.Events.PendingApprovals.list(actor)
        end
      end)
    end
  end

  mutation do
    @desc "使用邮箱密码登录（#60 路径 B：httpOnly cookie 交付 token）"
    field :sign_in, :sign_in_result do
      arg(:email, non_null(:string))
      arg(:password, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:email])

      resolve(fn _, %{email: email, password: password}, _ ->
        query =
          Cgc2046.Accounts.User
          |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: password})

        try do
          case Ash.read(query) do
            {:ok, [user]} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: user.__metadata__[:token]
               }}

            {:error, _error} ->
              {:error, message: "Invalid email or password", code: "authentication_failed"}
          end
        rescue
          _ -> {:error, message: "Invalid email or password", code: "authentication_failed"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "注册新用户（#60 路径 B：httpOnly cookie 交付 token，自动登录）"
    field :sign_up, :sign_up_payload do
      arg(:input, non_null(:sign_up_input))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:input, :email])

      resolve(fn _, %{input: %{email: email, password: password}}, %{context: context} ->
        changeset =
          Cgc2046.Accounts.User
          |> Ash.Changeset.for_create(:register_with_password, %{email: email, password: password})

        try do
          case Ash.create(changeset) do
            {:ok, user} ->
              token = user.__metadata__[:token]

              # ADR-0004 §3.5：新用户自动加入默认社区 workspace 2046（member 角色）
              # + 建 per-workspace 档案。失败降级不阻断注册（2046 是保障而非硬依赖）。
              # 故意宽捕 rescue：入座失败不应让注册 500（user 已建，2046 是兜底），
              # 包括编程错误也一律降级为 warning 日志——后续排查依赖该日志，不静默吞掉。
              try do
                case Cgc2046.Accounts.MembershipContext.admit_to_default_workspace(user.id) do
                  {:ok, _} ->
                    :ok

                  {:error, reason} ->
                    Logger.warning("[signUp] default workspace enroll failed: #{inspect(reason)}")
                end
              rescue
                error ->
                  Logger.warning(
                    "[signUp] default workspace enroll raised: #{Exception.message(error)}"
                  )
              end

              {:ok,
               %{
                 result: %{
                   id: user.id,
                   email: user.email,
                   is_platform_admin: user.is_platform_admin
                 },
                 errors: [],
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: token
               }}

            {:error, %Ash.Error.Invalid{} = error} ->
              # AshGraphql.Error protocol 映射（message/code/fields），与
              # update_profile / set_ui_theme 同源（to_ash_graphql_errors）——前端可按
              # code/fields 分流（如唯一性冲突 → invalid_attribute + fields: [:email]）。
              {:ok,
               %{
                 result: nil,
                 errors: to_ash_graphql_errors(error, context, :register_with_password),
                 __token__: nil
               }}

            {:error, _error} ->
              {:ok,
               %{
                 result: nil,
                 errors: [
                   %{
                     message: "Registration failed. Please check your input and try again.",
                     code: "registration_failed"
                   }
                 ],
                 __token__: nil
               }}
          end
        rescue
          _ ->
            {:ok,
             %{
               result: nil,
               errors: [
                 %{
                   message: "Registration failed. Please check your input and try again.",
                   code: "registration_failed"
                 }
               ],
               __token__: nil
             }}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "小程序平台一键登录（N1，Phase 1）：code2session + 平台手机号锚定统一身份，token 经 httpOnly cookie 交付"
    field :sign_in_with_platform, :sign_in_with_platform_result do
      arg(:platform, non_null(:string))
      arg(:code, non_null(:string))
      arg(:encrypted_data, non_null(:string))
      arg(:iv, non_null(:string))

      # getPhoneNumber 计费防刷：复用既有 RateLimit（按 IP+platform 计，5 次/15 分钟）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:platform])

      resolve(fn _,
                 %{platform: platform, code: code, encrypted_data: encrypted_data, iv: iv},
                 _ ->
        query =
          Cgc2046.Accounts.User
          |> Ash.Query.for_read(:sign_in_with_miniprogram, %{
            platform: platform,
            code: code,
            encrypted_data: encrypted_data,
            iv: iv
          })

        try do
          case Ash.read(query) do
            {:ok, [user]} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: user.__metadata__[:token]
               }}

            {:error, _error} ->
              {:error, message: "Platform sign in failed", code: "authentication_failed"}
          end
        rescue
          _ -> {:error, message: "Platform sign in failed", code: "authentication_failed"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "Owner/Admin 创建一次性工作台邀请小程序码"
    field :generate_mini_program_code, :miniprogram_code_result do
      arg(:workspace_id, non_null(:id))
      arg(:platform, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:workspace_id])

      resolve(fn _, %{workspace_id: workspace_id, platform: platform}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            case Cgc2046.MiniprogramCode.generate(workspace_id, actor, platform) do
              {:ok, result} ->
                {:ok, result}

              {:error, :forbidden} ->
                {:error, message: "Forbidden", code: "forbidden"}

              {:error, :invalid_platform} ->
                {:error, message: "Invalid platform", code: "invalid_platform"}

              {:error, :daily_quota_exhausted} ->
                {:error, message: "Daily quota exhausted", code: "daily_quota_exhausted"}

              {:error, _} ->
                {:error, message: "Code generation failed", code: "code_generation_failed"}
            end
        end
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

          not Cgc2046.MiniprogramCode.valid_scene?(scene) ->
            {:error, message: "Invalid scene", code: "invalid_scene"}

          true ->
            actor = context[:actor]

            with {:ok, code} <- Cgc2046.MiniprogramCode.code_for_scene(scene),
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

    @desc "记录一次小程序订阅消息授权并增加一个可用次数"
    field :grant_mini_program_notification_consent, :integer do
      arg(:platform, non_null(:string))
      arg(:template_key, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:platform])

      resolve(fn _, %{platform: platform, template_key: template_key}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            case Cgc2046.NotificationConsent.grant(actor.id, platform, template_key) do
              {:ok, remaining} ->
                {:ok, remaining}

              {:error, :invalid_platform} ->
                {:error, message: "Invalid platform", code: "invalid_platform"}

              {:error, _} ->
                {:error, message: "Consent grant failed", code: "consent_grant_failed"}
            end
        end
      end)
    end

    @desc "登出：服务端撤销当前 token 并清除 httpOnly cookie（token 被偷也无法重放）"
    field :sign_out, :string do
      resolve(fn _, _, _ ->
        {:ok, "signed_out"}
      end)

      middleware(fn res, _ ->
        revoke_bearer_token(res.context)
        %{res | context: Map.put(res.context, :cgc_clear_token, true)}
      end)
    end

    @desc "更新当前用户全局显示名（ADR-0004：displayName 保留全局身份字段）"
    field :update_display_name, :user do
      arg(:display_name, non_null(:string))

      resolve(fn _, %{display_name: display_name}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
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
        end
      end)
    end

    @desc "更新当前用户在某工作台的资料（ADR-0004 per-workspace）"
    field :update_workspace_profile, :workspace_profile do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:update_workspace_profile_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            case Cgc2046.Accounts.WorkspaceProfile
                 |> Ash.Query.for_read(:read)
                 |> Ash.Query.filter(user_id == ^actor.id)
                 |> Ash.read_one(tenant: workspace_id, actor: actor) do
              {:ok, nil} ->
                {:error,
                 message: "Workspace profile not found or not accessible",
                 code: "workspace_profile_not_found"}

              {:ok, profile} ->
                profile
                |> Ash.Changeset.for_update(:update_profile, map_input(input))
                |> Ash.update(tenant: workspace_id, actor: actor)

              {:error, error} ->
                {:error,
                 to_ash_graphql_errors(
                   error,
                   context,
                   :update_workspace_profile,
                   Cgc2046.Accounts.WorkspaceProfile
                 )}
            end
        end
      end)
    end

    @desc "设置当前用户在某工作台的 UI 主题偏好（ADR-0004 per-workspace）"
    field :set_workspace_theme, :workspace_profile do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:set_workspace_theme_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            case Cgc2046.Accounts.WorkspaceProfile
                 |> Ash.Query.for_read(:read)
                 |> Ash.Query.filter(user_id == ^actor.id)
                 |> Ash.read_one(tenant: workspace_id, actor: actor) do
              {:ok, nil} ->
                {:error,
                 message: "Workspace profile not found or not accessible",
                 code: "workspace_profile_not_found"}

              {:ok, profile} ->
                profile
                |> Ash.Changeset.for_update(:set_ui_theme, %{
                  ui_theme_preference: input.ui_theme_preference
                })
                |> Ash.update(tenant: workspace_id, actor: actor)

              {:error, error} ->
                {:error,
                 to_ash_graphql_errors(
                   error,
                   context,
                   :set_workspace_theme,
                   Cgc2046.Accounts.WorkspaceProfile
                 )}
            end
        end
      end)
    end

    @desc "在某工作台创建作品集条目（ADR-0004；workspace_id 与 user_id 自动填充，防跨租户伪造）"
    field :create_portfolio_item, :portfolio_item do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:create_portfolio_item_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            attrs = map_input(input, [:title, :description, :url, :icon])

            Cgc2046.Accounts.PortfolioItem
            |> Ash.Changeset.for_create(:create, attrs)
            |> Ash.create(tenant: workspace_id, actor: actor)
        end
      end)
    end

    @desc "更新某工作台自己的作品集条目（ADR-0004；tenant 隔离）"
    field :update_portfolio_item, :portfolio_item do
      arg(:id, non_null(:id))
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:update_portfolio_item_input))

      resolve(fn _, %{id: id, workspace_id: workspace_id, input: input}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            attrs = map_input(input, [:title, :description, :url, :icon])

            with {:ok, item} <-
                   Cgc2046.Accounts.PortfolioItem
                   |> Ash.get(id, tenant: workspace_id, actor: actor) do
              item
              |> Ash.Changeset.for_update(:update, attrs)
              |> Ash.update(tenant: workspace_id, actor: actor)
            end
        end
      end)
    end

    @desc "删除某工作台自己的作品集条目（ADR-0004；tenant 隔离）"
    field :delete_portfolio_item, :portfolio_item do
      arg(:id, non_null(:id))
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{id: id, workspace_id: workspace_id}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            with {:ok, item} <-
                   Cgc2046.Accounts.PortfolioItem
                   |> Ash.get(id, tenant: workspace_id, actor: actor) do
              case Ash.destroy(item, tenant: workspace_id, actor: actor) do
                :ok -> {:ok, item}
                {:error, error} -> {:error, error}
              end
            end
        end
      end)
    end

    @desc "签发 MCP 连接 token（切片 D #44；明文仅本次经 plainToken 返回一次，库中只存 SHA256 hash）"
    field :create_mcp_token, :create_mcp_token_payload do
      arg(:name, non_null(:string))

      resolve(fn _, %{name: name}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
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
        end
      end)
    end

    @desc "撤销 MCP 连接 token（切片 D #44；仅本人，置 revokedAt 保留审计行；他人 token 一律 not_found 不泄露存在性）"
    field :revoke_mcp_token, :mcp_token do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            case Cgc2046.Mcp.Token.revoke(id, actor) do
              {:ok, revoked} ->
                {:ok, revoked}

              {:error, :not_found} ->
                # NotFound（他人 token / 不存在 id）统一塌缩，不泄露存在性
                {:error, [message: "not found", code: "not_found"]}

              {:error, {:invalid, error}} ->
                {:error,
                 to_ash_graphql_errors(error, context, :revoke, Cgc2046.Mcp.Token, Cgc2046.Mcp)}
            end
        end
      end)
    end
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
      description: "角色名：owner / admin / member / tutor / volunteer / learner"
    )

    field(:abilities, non_null(list_of(non_null(:ability_grant))))
  end

  object :permission_matrix_payload do
    field(:roles, non_null(list_of(non_null(:permission_matrix_row))))
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
  end

  object :miniprogram_code_result do
    field(:invitation_id, non_null(:id))
    field(:platform, non_null(:string))
    field(:scene, non_null(:string))
    field(:code_base64, non_null(:string))
    field(:expires_at, non_null(:datetime))
  end

  # ── 认证相关类型（#60 路径 B：httpOnly cookie 交付 token） ──────────────

  # 持 token 的邀请接口限流：validate/accept 均吃明文 token 参数，按 IP+token 计，
  # 5 次/15 分钟（复用 RateLimit plug，与 sign_in/sign_up 同档位）。
  # token 为 256-bit 强随机，枚举不成立；此为已知 token 被滥用探测时的加固。
  # arity-3：Absinthe 的 middleware callback 是 arity-3（schema.middleware(mw, field, object)），
  # arity-2 不会被框架调用。
  def middleware(middleware, %{identifier: :validate_invitation}, _object),
    do: [{Cgc2046Web.Plugs.RateLimit, key_path: [:token]} | middleware]

  def middleware(middleware, %{identifier: :accept_invitation}, _object),
    do: [{Cgc2046Web.Plugs.RateLimit, key_path: [:input, :token]} | middleware]

  def middleware(middleware, _field, _object), do: middleware

  object :sign_in_result do
    field(:id, non_null(:id))
    field(:email, non_null(:string))
    field(:is_platform_admin, non_null(:boolean))
  end

  # 小程序手机号用户无邮箱 → email 可空（与 users.email 放宽一致）
  object :sign_in_with_platform_result do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:is_platform_admin, non_null(:boolean))
  end

  object :sign_up_payload do
    field(:result, :sign_up_user)
    field(:errors, list_of(:mutation_error))
  end

  object :sign_up_user do
    field(:id, non_null(:id))
    field(:email, non_null(:string))
    field(:is_platform_admin, non_null(:boolean))
  end

  input_object :sign_up_input do
    field(:email, non_null(:string))
    field(:password, non_null(:string))
  end

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

  # 未登录统一错误形状（message + code），供 me / update_profile / set_ui_theme
  # 的 actor nil 分支复用——与 sign_in 的 keyword list 错误走同一序列化路径。
  defp unauthorized_error, do: [message: "unauthorized", code: "unauthorized"]

  # Ash action 错误 → AshGraphql.Error 结构化顶层 error（message/code/fields）。
  # 复用 AshGraphql.Errors.to_errors（自动生成 mutation 同款映射），与 sign_up 的
  # 错误协议一致；只取最小形状字段，避免 vars/short_message 等内部字段进响应。
  # domain 默认 GlobalApi（历史调用方均属此域）；其它域的资源（如 Cgc2046.Mcp.Token）须显式传入。
  defp to_ash_graphql_errors(
         error,
         context,
         action,
         resource \\ Cgc2046.Accounts.User,
         domain \\ Cgc2046.GlobalApi
       ) do
    error
    |> AshGraphql.Errors.to_errors(context, domain, resource, action)
    |> Enum.map(&Map.take(&1, [:message, :code, :fields]))
  end

  # 把 Absinthe input map 转为 Ash attrs map（只取指定字段，忽略缺省）。
  # map_input(input, keys)：keys 内存在才放进去；
  # map_input(input)：全量取（用于 update_workspace_profile_input 的全部可选字段）。
  defp map_input(input, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case input do
        %{^key => value} -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp map_input(input) do
    map_input(input, [:avatar_url, :location, :about, :skills, :visibility])
  end

  # 统一的个人资料加载：member_number/joined_at 为计算属性，获取与更新后均需显式加载。
  # 加载失败（罕见：calculation/DB 异常）经 to_ash_graphql_errors 映射，与
  # update_profile/set_ui_theme 同源——避免把 Ash 内部 stacktrace 当 string 返给客户端。
  # `action` 用于错误路径解析（与出错 mutation 的 action 对齐，nil 表示 query 侧 me）。
  defp load_profile(user, actor, context, action) do
    case Ash.load(user, [:member_number, :joined_at],
           actor: actor,
           domain: Cgc2046.GlobalApi
         ) do
      {:ok, loaded} ->
        {:ok, loaded}

      {:error, error} ->
        {:error, to_ash_graphql_errors(error, context, action)}
    end
  end

  # 服务端撤销当前 token：往 tokens 表对当前 jti 做 upsert，把 purpose 从 "user"
  # 覆盖成 "revocation"，下次 load_from_bearer 的 get_token 查不到 user 记录即认证失败。
  # token 由 AuthTokenContextPlug 从 Authorization header 透传进 Absinthe context。
  # 撤销失败不阻断登出：仍清 cookie 让用户侧登出成功，token 会在 7 天自然过期。
  defp revoke_bearer_token(context) do
    case context[:cgc_bearer_token] do
      token when is_binary(token) and byte_size(token) > 0 ->
        case AshAuthentication.TokenResource.Actions.revoke(Cgc2046.Accounts.Token, token, []) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("signOut token revoke failed: #{inspect(reason)}")
        end

      _ ->
        :ok
    end
  end
end
