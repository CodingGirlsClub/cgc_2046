defmodule Cgc2046.Mcp.Tools.AdminListReconciliationFindings do
  @moduledoc """
  平台治理：对账发现读面（reconciliation_findings 的 MCP 面）。

  `Cgc2046.Reconciliation.ReconciliationScanWorker` 每 10 分钟扫十二条规则，
  命中落 Finding 表（刷新语义：命中 upsert 保 first_seen_at，未命中删除）。
  本工具把该表接到 agent 工作流——owner/管理员问「工作台健康吗」时，
  agent 可查当前孤儿清单并指出消解方向（如：工作台缺协议定义 → 需
  补种 `Workflows.ProtocolDefinitions`）。

  过滤参数均可选：`rule`（规则枚举，见 Finding moduledoc）、`workspace_id`。
  按 last_seen_at 倒序，封顶 50 条。

  授权 = Wrapper `:platform_admin` 门控族 + Finding read policy 的
  PlatformAdmin 放行（与 /admin/reconciliation 对账页同款）。

  投影与对账页**有意不同**：GraphQL 对账面（人工列表页）v1 决策不暴露
  detail（graphql_schema.ex `:admin_reconciliation_finding` 注释）；本面
  供 agent 排查，透出 detail 的**白名单投影**作消解方向指引。两面受众不同，
  口径分叉是 deliberate，非疏漏。

  `detail` 收口（#631，与 #612 的 `error_message` 同类通道）：写入面是 4 个
  worker / 17 条规则（键集穷举于 `@detail_keys`），其中规6 `error`（Oban 存的
  `Exception.format` 全文，含 stacktrace）与规15 `last_error`（`inspect/1` 原文）
  是**原始错误文本**——按 #612 纪律不出面，落固定摘要（原文留在服务端
  `oban_jobs.errors` / `notification_deliveries.last_error`，AshAdmin 可查）。
  `@detail_keys` 是**手工维护点**：取向 fail-closed——未登记键（含未来新规则的键）
  一律不出面，新键须人工确认后登记。
  """

  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.AdminList
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Reconciliation.Finding

  require Ash.Query

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    平台管理员专用：列出对账扫描当前发现的问题（后台每 10 分钟扫描一次，问题消失后自动移除），用于
    回答「工作台健康吗」一类问题并指出处理方向。rule、workspace_id 均为可选过滤。按最近发现时间倒序，
    最多 50 条。detail 只含白名单字段；原始错误文本不返回，只给固定摘要，原文需在服务端后台查看。
    """
  end

  schema do
    field(:rule, :string, description: "按规则过滤（可选；如 open_entity_without_research_definition）")

    field(:workspace_id, :string, description: "按工作台过滤（可选；全局实体如死信 job 无租户）")
  end

  # detail 键白名单（2026-09 取证：4 个 worker / 17 条规则穷举）。fail-closed：
  # 未登记键一律不出面（新规则新键须在此登记才可见）。
  @detail_keys ~w(event_id course_id user_id sponsor_user_id level title run_id status
                  worker signal_type enrollment_id last_activity_at occupancy
                  enrollment_count sync_version confirmed_count
                  confirmed_count_sync_version capacity drifts actions window_seconds
                  threshold reason paid_deposit_orders paid_cents template_key platform
                  attempts kind channel_cents channel_status no_local_order local_status
                  local_cents expire_at since expected_cents)

  # 原始错误文本键 → 固定摘要（#612 纪律：原文只留服务端）
  @raw_error_keys ~w(error last_error)
  @raw_error_summary "[withheld: raw error text is server-side only]"

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_list_reconciliation_findings", fn actor, _ws, params ->
        with {:ok, rule} <- parse_rule(params["rule"]),
             {:ok, workspace_id} <-
               parse_workspace_id(params["workspace_id"]),
             {:ok, rows} <- read_findings(actor, rule, workspace_id) do
          {:ok, %{count: length(rows), findings: rows}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 空串/nil = 不过滤；值必须落在 Finding @rule_values 内（报错带合法清单）
  defp parse_rule(nil), do: {:ok, nil}
  defp parse_rule(""), do: {:ok, nil}

  defp parse_rule(rule) when is_binary(rule) do
    rules = Cgc2046.Reconciliation.Finding.rule_values()

    case Enum.find(rules, &(to_string(&1) == rule)) do
      nil -> {:error, "invalid rule (expected one of #{Enum.map_join(rules, "|", &to_string/1)})"}
      atom -> {:ok, atom}
    end
  end

  defp parse_rule(_), do: {:error, "rule must be a string"}
  # 空串/nil = 不过滤；值须为 UUID 形态（非法串在 filter 前拦截，
  # 不进 Ash.Query 的 uuid cast 报深层 query error）
  defp parse_workspace_id(nil), do: {:ok, nil}
  defp parse_workspace_id(""), do: {:ok, nil}

  defp parse_workspace_id(workspace_id) when is_binary(workspace_id) do
    case Ecto.UUID.cast(workspace_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "invalid workspace_id (expected UUID)"}
    end
  end

  defp parse_workspace_id(_), do: {:error, "workspace_id must be a string"}

  # 读取纪律同 admin_list_audit_logs：for_read(:read) + actor 授权 + 倒序封顶；
  # 投影白名单在 to_row，detail 经 project_detail/1 收口。
  defp read_findings(actor, rule, workspace_id) do
    Finding
    |> Ash.Query.for_read(:read)
    |> AdminList.recent(:last_seen_at)
    |> filter_rule(rule)
    |> filter_workspace(workspace_id)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, findings} -> {:ok, Enum.map(findings, &to_row/1)}
      {:error, _} = err -> err
    end
  end

  defp filter_rule(query, nil), do: query
  defp filter_rule(query, rule), do: Ash.Query.filter(query, rule == ^rule)

  defp filter_workspace(query, nil), do: query
  defp filter_workspace(query, ""), do: query

  defp filter_workspace(query, workspace_id),
    do: Ash.Query.filter(query, workspace_id == ^workspace_id)

  # detail 投影：白名单键原样保留 + 原始错误文本键落固定摘要 + 其余键丢弃。
  # 键统一 to_string 归一（17 个构造点 atom/string 键混用；JSON 编码后同形），
  # 未知形状（nil/非 map，DB 层 NOT NULL 下不会出现）→ 空 map。
  defp project_detail(detail) when is_map(detail) do
    Enum.reduce(detail, %{}, fn {key, value}, acc ->
      key = to_string(key)

      cond do
        key in @raw_error_keys -> Map.put(acc, key, @raw_error_summary)
        key in @detail_keys -> Map.put(acc, key, value)
        true -> acc
      end
    end)
  end

  defp project_detail(_detail), do: %{}

  defp to_row(finding) do
    %{
      id: finding.id,
      rule: finding.rule,
      entity_type: finding.entity_type,
      entity_id: finding.entity_id,
      workspace_id: finding.workspace_id,
      detail: project_detail(finding.detail),
      first_seen_at: finding.first_seen_at,
      last_seen_at: finding.last_seen_at
    }
  end
end
