defmodule Cgc2046Web.GraphqlSchema do
  use Absinthe.Schema

  require Logger

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

    @desc "当前登录用户个人资料（#68 Profile API，需登录）：id/email/displayName/avatarUrl/isPlatformAdmin + P1 扩展字段"
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

    @desc "更新当前用户个人资料（#68）：displayName 必填（trim 后非空），avatarUrl 可选"
    field :update_profile, :user do
      arg(:input, non_null(:update_profile_input))

      resolve(fn _, %{input: input}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            attrs =
              Enum.reduce(
                [
                  :display_name,
                  :avatar_url,
                  :location,
                  :about,
                  :skills,
                  :visibility
                ],
                %{},
                fn key, acc ->
                  case input do
                    %{^key => value} -> Map.put(acc, key, value)
                    _ -> acc
                  end
                end
              )

            case Ash.update(actor, attrs, action: :update_profile, actor: actor) do
              {:ok, user} ->
                load_profile(user, actor, context, :update_profile)

              {:error, error} ->
                {:error, to_ash_graphql_errors(error, context, :update_profile)}
            end
        end
      end)
    end

    @desc "设置当前用户 UI 主题偏好（U3）：dark | light，服务端持久化"
    field :set_ui_theme, :user do
      arg(:input, non_null(:set_ui_theme_input))

      resolve(fn _, %{input: input}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, unauthorized_error()}

          actor ->
            case Ash.update(actor, %{ui_theme_preference: input.ui_theme_preference},
                   action: :set_ui_theme,
                   actor: actor
                 ) do
              {:ok, user} ->
                load_profile(user, actor, context, :set_ui_theme)

              {:error, error} ->
                {:error, to_ash_graphql_errors(error, context, :set_ui_theme)}
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

  # ── 个人资料相关类型 ──────────────────────────────────────────────────

  input_object :update_profile_input do
    @desc "updateProfile 输入（P1）：displayName 必填，avatarUrl/location/about/skills/visibility 可选"
    field(:display_name, non_null(:string))
    field(:avatar_url, :string)
    field(:location, :string)
    field(:about, :string)
    field(:skills, list_of(:string))
    field(:visibility, :string)
  end

  input_object :set_ui_theme_input do
    @desc "setUiTheme 输入（U3）：uiThemePreference 必填，仅 dark | light"
    field(:ui_theme_preference, non_null(:string))
  end

  # 未登录统一错误形状（message + code），供 me / update_profile / set_ui_theme
  # 的 actor nil 分支复用——与 sign_in 的 keyword list 错误走同一序列化路径。
  defp unauthorized_error, do: [message: "unauthorized", code: "unauthorized"]

  # Ash action 错误 → AshGraphql.Error 结构化顶层 error（message/code/fields）。
  # 复用 AshGraphql.Errors.to_errors（自动生成 mutation 同款映射），与 sign_up 的
  # 错误协议一致；只取最小形状字段，避免 vars/short_message 等内部字段进响应。
  defp to_ash_graphql_errors(error, context, action) do
    error
    |> AshGraphql.Errors.to_errors(context, Cgc2046.GlobalApi, Cgc2046.Accounts.User, action)
    |> Enum.map(&Map.take(&1, [:message, :code, :fields]))
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
  # 撤销失败不阻断登出：仍清 cookie 让用户侧登出成功，token 会在 14 天自然过期。
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
