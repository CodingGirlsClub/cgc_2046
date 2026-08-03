defmodule Cgc2046Web.GraphqlSchema do
  use Absinthe.Schema

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
            {:ok, load_profile(actor, actor)}
        end
      end)
    end
  end

  mutation do
    @desc "使用邮箱密码登录（#60 路径 B：httpOnly cookie 交付 token）"
    field :sign_in, :sign_in_result do
      arg(:email, non_null(:string))
      arg(:password, non_null(:string))

      resolve(fn _, %{email: email, password: password}, _ ->
        query =
          Cgc2046.Accounts.User
          |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: password})

        case Ash.read(query) do
          {:ok, [user]} ->
            {:ok,
             %{
               id: user.id,
               email: user.email,
               is_platform_admin: user.is_platform_admin,
               token: user.__metadata__[:token]
             }}

          {:error, _error} ->
            {:error, message: "Invalid email or password", code: "authentication_failed"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{token: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "注册新用户（#60 路径 B：httpOnly cookie 交付 token，自动登录）"
    field :sign_up, :sign_up_payload do
      arg(:input, non_null(:sign_up_input))

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
               metadata: %{token: token}
             }}

          {:error, error} ->
            message = error |> Ash.Error.to_error_class() |> Exception.message()
            {:ok, %{result: nil, errors: [%{message: message, code: nil}], metadata: nil}}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{metadata: %{token: token}} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
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
                {:ok, load_profile(user, actor)}

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
                {:ok, load_profile(user, actor)}

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
    field(:token, :string)
  end

  object :sign_up_payload do
    field(:result, :sign_up_user)
    field(:errors, list_of(:auth_mutation_error))
    field(:metadata, :sign_up_metadata)
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

  object :sign_up_metadata do
    field(:token, :string)
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
    Ash.load!(user, [:member_number, :joined_at],
      actor: actor,
      domain: Cgc2046.GlobalApi
    )
  end
end
