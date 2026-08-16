# 课程 issue 学习闭环种子(切片 H U5, #180)。
#
# 四件(幂等,存在即跳过):
#   1. 教研 workflow 定义(单 manual step 协议容器,published)
#   2. 学习 workflow 定义(单 manual step 协议容器,published)
#   3. 学习 Agent 指令(八步循环 + kind 分支 + 产物实查,不采信口头完成)
#   4. 教研 Agent 指令(起草规则含 id 稳定纪律)
#
# 种子进默认 workspace(slug "2046",ADR-0004 §3.5;不存在则提示跳过——
# 种子不负责建租户)。Agent 指令以 Cgc2046.Workflows.AgentInstructions
# 纯文本模块为载体(get_agent_instruction 工具/Agent 资源系 roadmap,
# plan 020 U4 明示不实现;指令先落可消费的模块常量,后续接工具时切库)。
#
# 运行:mix run priv/repo/seeds.exs(ecto.setup 自动执行)。

alias Cgc2046.Accounts.Workspace
alias Cgc2046.Workflows.AgentInstructions
alias Cgc2046.Workflows.WorkflowDefinition

require Ash.Query

{:ok, default_workspace} =
  Workspace
  |> Ash.Query.for_read(:get_by_slug, %{slug: "2046"})
  |> Ash.read_one(authorize?: false)

case default_workspace do
  nil ->
    IO.puts("[seeds] default workspace (slug 2046) not found; skip learning loop seeds")

  workspace ->
    definitions = [
      %{
        name: "教研 workflow",
        type: :research,
        node_def: %{"steps" => [%{"id" => "produce_issue_deck", "type" => "manual"}]}
      },
      %{
        name: "学习 workflow",
        type: :learning,
        node_def: %{"steps" => [%{"id" => "learning_loop", "type" => "manual"}]}
      }
    ]

    Enum.each(definitions, fn attrs ->
      existing =
        WorkflowDefinition
        |> Ash.Query.filter(name == ^attrs.name and type == ^attrs.type and status == :published)
        |> Ash.read_one(authorize?: false, tenant: workspace.id)

      case existing do
        {:ok, nil} ->
          {:ok, defn} =
            WorkflowDefinition
            |> Ash.Changeset.for_create(
              :create,
              Map.merge(attrs, %{input_schema: %{}}),
              tenant: workspace.id,
              authorize?: false
            )
            |> Ash.create(tenant: workspace.id, authorize?: false)

          {:ok, _published} =
            defn
            |> Ash.Changeset.for_update(:publish, %{}, authorize?: false)
            |> Ash.update(tenant: workspace.id, authorize?: false)

          IO.puts("[seeds] published #{attrs.type} definition: #{attrs.name}")

        {:ok, _} ->
          IO.puts("[seeds] #{attrs.type} definition already published; skip")

        {:error, reason} ->
          IO.puts("[seeds] definition lookup failed: #{inspect(reason)}")
      end
    end)

    # Agent 指令种子:模块常量已是幂等载体(重复运行同一文本);
    # 打印确认落位(get_agent_instruction 工具落地后切库)。
    IO.puts(
      "[seeds] learning agent instruction: #{byte_size(AgentInstructions.learning_agent())} bytes"
    )

    IO.puts(
      "[seeds] research agent instruction: #{byte_size(AgentInstructions.research_agent())} bytes"
    )
end
