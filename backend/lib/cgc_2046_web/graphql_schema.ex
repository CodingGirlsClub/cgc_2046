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
  end

  mutation do
  end
end
