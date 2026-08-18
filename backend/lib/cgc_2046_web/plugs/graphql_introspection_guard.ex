defmodule Cgc2046Web.Plug.GraphqlIntrospectionGuard do
  @moduledoc """
  VULN-001（#81）：非 dev 环境拒绝 GraphQL introspection（`__schema`/`__type`）。

  document pipeline modifier——经 `Absinthe.Plug` 的 `:pipeline` 选项挂载，
  在 `Absinthe.Phase.Document.Validation.Result` 之前插入
  `Cgc2046Web.Plug.GraphqlIntrospectionGuard.Block` phase：对顶层 selection 中的
  `__schema`/`__type` 字段标记 invalid 并注入 validation error（HTTP 200 + errors，
  标准 GraphQL 语义）。dev（Playground 同门控 `dev_routes`）放行。

  注：`Absinthe.Plug` 1.5.10 的 `@init_options` 不含 `:introspection` 选项，故不能
  走 plug 选项关闭；schema 编译期移除 Introspection phase 会连规范字段
  `__typename` 一起移除（破坏客户端），故在 document 层精准拦截。
  """

  @dev_routes Application.compile_env(:cgc_2046, :dev_routes, false)

  @spec pipeline(map, keyword()) :: Absinthe.Pipeline.t()
  def pipeline(config, pipeline_opts) do
    pipeline = Absinthe.Plug.default_pipeline(config, pipeline_opts)

    if @dev_routes do
      pipeline
    else
      Absinthe.Pipeline.insert_before(
        pipeline,
        Absinthe.Phase.Document.Validation.Result,
        Cgc2046Web.Plug.GraphqlIntrospectionGuard.Block
      )
    end
  end
end

defmodule Cgc2046Web.Plug.GraphqlIntrospectionGuard.Block do
  @moduledoc false

  use Absinthe.Phase

  alias Absinthe.{Blueprint, Phase}

  @introspection_fields ~w(__schema __type)

  @impl Absinthe.Phase
  def run(blueprint, _opts) do
    {:ok, Blueprint.postwalk(blueprint, &guard_operation/1)}
  end

  defp guard_operation(%Blueprint.Document.Operation{} = op) do
    %{op | selections: Enum.map(op.selections, &guard_field/1)}
  end

  defp guard_operation(node), do: node

  defp guard_field(%Blueprint.Document.Field{name: name} = field)
       when name in @introspection_fields do
    field
    |> flag_invalid(:introspection_disabled)
    |> put_error(%Phase.Error{
      message: "Introspection is disabled",
      phase: __MODULE__,
      locations: field_locations(field)
    })
  end

  defp guard_field(node), do: node

  defp field_locations(%{source_location: %{line: line, column: column}})
       when is_integer(line) and is_integer(column) do
    [%{line: line, column: column}]
  end

  defp field_locations(_), do: []
end
