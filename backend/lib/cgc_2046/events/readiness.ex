defmodule Cgc2046.Events.Readiness do
  @moduledoc """
  GO/NO-GO readiness 清单（E-5 #50，D3 拍板：v1 警告放行 + readiness 查询暴露后台）。

  清单 v1（D3 定稿）：
  1. `registration_deadline` 已设（null 合法 = 不设截止，仅提示）；
  2. published research 定义存在（无则教研 run 不会实例化，
     research_instantiator 静默跳过——对账规则④同源）。

  sponsorship 配置项 v1 不评估：`sponsorship_enabled` 字段尚未落库
  （总纲:90 规划，随 E-3 补上后追加清单项）。

  语义：清单非 ready 不阻塞 launch（D3 警告放行），仅记 warning 日志 +
  经 GraphQL 查询向后台暴露。
  """

  require Ash.Query
  require Logger

  alias Cgc2046.Workflows.WorkflowDefinition

  @spec evaluate(map()) :: %{items: [map()], ready: boolean()}
  def evaluate(entity) do
    items = [
      %{
        key: "registration_deadline",
        label: "报名截止已设置",
        ok: not is_nil(entity.registration_deadline)
      },
      %{
        key: "research_definition",
        label: "已发布教研 workflow 定义",
        ok: research_definition_published?(entity.workspace_id)
      }
    ]

    %{items: items, ready: Enum.all?(items, & &1.ok)}
  end

  @doc """
  GO/NO-GO 发布警告（D3 警告放行）：launch 后清单非 ready 记 warning 不阻塞发布，
  明细经 GraphQL readiness 查询暴露后台。after_transaction 回调形态（Event/Course
  launch 共用）——仅成功结果评估，原样透传 result。
  """
  def warn_unless_ready(_changeset, result, _context) do
    with {:ok, record} <- result,
         %{ready: false, items: items} <- evaluate(record) do
      missing = items |> Enum.reject(& &1.ok) |> Enum.map_join(", ", & &1.label)
      Logger.warning("GO/NO-GO: launched with missing readiness items: #{missing}")
    end

    result
  end

  # 已发布教研定义（多个取任意即可，实例化取最新）——查询失败视为未就绪
  # （fail-closed：宁可提示不可静默放行）。
  defp research_definition_published?(workspace_id) do
    case WorkflowDefinition
         |> Ash.Query.filter(type == :research and status == :published)
         |> Ash.read_first(tenant: workspace_id, authorize?: false) do
      {:ok, %WorkflowDefinition{}} -> true
      {:ok, nil} -> false
      {:error, _} -> false
    end
  end
end
