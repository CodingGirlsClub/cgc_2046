defmodule Cgc2046Web.GraphqlSchema do
  use Absinthe.Schema

  require Logger

  use AshGraphql,
    domains: [Cgc2046.Api, Cgc2046.GlobalApi],
    generate_sdl_file: "priv/graphql/schema.graphql",
    auto_generate_sdl_file?: true

  import_types(Cgc2046Web.GraphqlSchema.RbacTypes)

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
            {:error, "unauthorized"}

          actor ->
            load_profile(actor, actor)
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

      resolve(fn _, %{input: %{email: email, password: password}}, _ ->
        changeset =
          Cgc2046.Accounts.User
          |> Ash.Changeset.for_create(:register_with_password, %{email: email, password: password})

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

          {:error, error} ->
            message = error |> Ash.Error.to_error_class() |> Exception.message()
            {:ok, %{result: nil, errors: [%{message: message, code: nil}], __token__: nil}}
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
            {:error, "unauthorized"}

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
                load_profile(user, actor)

              {:error, error} ->
                message = Exception.message(Ash.Error.to_error_class(error))
                {:error, message}
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
            {:error, "unauthorized"}

          actor ->
            case Ash.update(actor, %{ui_theme_preference: input.ui_theme_preference},
                   action: :set_ui_theme,
                   actor: actor
                 ) do
              {:ok, user} ->
                load_profile(user, actor)

              {:error, error} ->
                message = Exception.message(Ash.Error.to_error_class(error))
                {:error, message}
            end
        end
      end)
    end
  end

  # ── 认证相关类型（#60 路径 B：httpOnly cookie 交付 token） ──────────────

  object :sign_in_result do
    field(:id, non_null(:id))
    field(:email, non_null(:string))
    field(:is_platform_admin, non_null(:boolean))
  end

  object :sign_up_payload do
    field(:result, :sign_up_user)
    field(:errors, list_of(:auth_mutation_error))
  end

  object :sign_up_user do
    field(:id, non_null(:id))
    field(:email, non_null(:string))
    field(:is_platform_admin, non_null(:boolean))
  end

  object :auth_mutation_error do
    field(:message, :string)
    field(:code, :string)
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

  # 统一的个人资料加载：member_number/joined_at 为计算属性，获取与更新后均需显式加载
  defp load_profile(user, actor) do
    case Ash.load(user, [:member_number, :joined_at],
           actor: actor,
           domain: Cgc2046.GlobalApi
         ) do
      {:ok, loaded} ->
        {:ok, loaded}

      {:error, error} ->
        {:error, Exception.message(Ash.Error.to_error_class(error))}
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
