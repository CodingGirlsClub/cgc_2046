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
