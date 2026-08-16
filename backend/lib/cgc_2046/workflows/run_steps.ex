defmodule Cgc2046.Workflows.RunSteps do
  @moduledoc """
  WorkflowRun 步骤读取面计算（plan 020 U3/U4：#150 最小版 + #93）。

  把 run 绑定版本的步骤投影为 step_key/title/type/output_schema 列表：

  - step_key/title/type 来自 definition.steps（Step 资源行，标题权威源，见
    LearningProgress）；definition 按 definition_id 加载——即 run 创建时绑定的
    版本行（D-A2 版本快照，new_version 出新行不改旧行），**不读最新定义**。
  - output_schema 来自同版本的 node_def.steps[].output_schema
    （name/type/label/optional；宽松校验兼容旧数据——缺失/非 map 即 nil，前端回退
    FactsTree）。

  授权：计算随 WorkflowRun 读 action 求值，读 policy（成员 + 平台管理员）已门控。

  实现说明：在 calculate 内显式加载（不经 load statement——该路径会因 GraphQL
  select 裁剪导致字段 NotLoaded；且 run 记录的 workspace_id 也可能 NotLoaded，
  故 definition 按 PK 全局读（资源 global?(true)），steps 以 definition 自带
  workspace_id 为 tenant 加载——与 graphql_schema.ex read_learning_runs 同款授权
  旁路模式）。
  """

  use Ash.Resource.Calculation

  alias Cgc2046.Workflows.WorkflowDefinition

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn run -> project(run) end)
  end

  defp project(run) do
    {definition, steps} = load_bound_definition(run)
    schemas = node_def_schemas(definition && definition.node_def)

    Enum.map(steps, fn step ->
      %{
        step_key: step.step_key,
        title: step.title,
        type: to_string(step.type),
        output_schema: Map.get(schemas, step.step_key)
      }
    end)
  end

  # run 绑定版本的 definition（按 PK 全局读）+ 其 Step 行（tenant = definition
  # workspace_id）。失败/异常（不该发生：成员读路径）降级空步骤，不影响 run 主体。
  defp load_bound_definition(run) do
    with definition_id when is_binary(definition_id) <- run.definition_id,
         {:ok, definition} when not is_nil(definition) <-
           Ash.get(WorkflowDefinition, definition_id, authorize?: false),
         {:ok, loaded} <-
           Ash.load(definition, [:steps],
             tenant: definition.workspace_id,
             authorize?: false
           ) do
      steps = if is_list(loaded.steps), do: loaded.steps, else: []
      {loaded, steps}
    else
      _ -> {nil, []}
    end
  end

  # node_def.steps[] 的 id == Step.step_key；output_schema 缺失/非 map 忽略（宽松）。
  defp node_def_schemas(nil), do: %{}

  defp node_def_schemas(%{"steps" => steps}) when is_list(steps) do
    Enum.reduce(steps, %{}, fn
      %{"id" => id, "output_schema" => schema}, acc when is_binary(id) and is_map(schema) ->
        Map.put(acc, id, schema)

      _, acc ->
        acc
    end)
  end

  defp node_def_schemas(_node_def), do: %{}
end
