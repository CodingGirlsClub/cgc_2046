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

    @desc "角色权限矩阵（#66 Rbac）：三角色 × 六能力，对齐前端 #67 权限表（需登录）"
    field :permission_matrix, :permission_matrix_payload do
      resolve(fn _, _, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, "unauthorized"}

          _actor ->
            roles =
              Cgc2046.Rbac.matrix()
              |> Enum.map(fn row ->
                %{name: to_string(row.role), abilities: row.abilities}
              end)

            {:ok, %{roles: roles}}
        end
      end)
    end

    @desc "当前用户在指定工作台的能力列表（#66 Rbac 动态判定，需登录）"
    field :my_abilities, :my_abilities_payload do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        case context[:actor] do
          nil ->
            {:error, "unauthorized"}

          actor ->
            abilities =
              actor
              |> Cgc2046.Rbac.abilities(workspace_id: workspace_id)
              |> Enum.map(&to_string/1)

            {:ok, %{abilities: abilities}}
        end
      end)
    end

    @desc "当前登录用户个人资料（#68 Profile API，需登录）：id/email/displayName/avatarUrl/isPlatformAdmin"
    field :me, :user do
      resolve(fn _, _, %{context: context} ->
        case context[:actor] do
          nil -> {:error, "unauthorized"}
          actor -> {:ok, actor}
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
              input
              |> Map.take([:display_name, :avatar_url])
              |> Enum.reject(fn {_key, value} -> is_nil(value) end)
              |> Map.new()

            case Ash.update(actor, attrs, action: :update_profile, actor: actor) do
              {:ok, user} ->
                {:ok, user}

              {:error, error} ->
                message = Exception.message(Ash.Error.to_error_class(error))
                {:error, message}
            end
        end
      end)
    end
  end

  input_object :update_profile_input do
    @desc "updateProfile 输入（#68）：displayName 必填，avatarUrl 可选"
    field :display_name, non_null(:string)
    field :avatar_url, :string
  end
end
