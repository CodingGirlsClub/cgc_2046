defmodule Cgc2046.AdminList do
  @moduledoc """
  平台治理列表读的查询组合子库（2026-09-08 架构评审候选③自
  `Cgc2046Web.GraphqlSchema` 抽离）：「search 形状 / 状态过滤 / 时间范围 /
  workspace 过滤 / 稳定排序 + 封顶分页」契约的单源。

  全部为 `Ash.Query` 纯变换（query in → query out），无 IO、无授权判定
  （门控在调用方：web 侧 `with_admin`、MCP 侧 Wrapper 派生门控）。
  消费方：graphql_schema 的 admin_* 列表 query（maybe_* 组合子 + paginate）
  与 MCP `admin_list_*` 工具（maybe_*_search + recent「倒序封顶」骨架）。
  """

  require Ash.Query

  # 「倒序封顶」读取骨架（web 侧 paginate 与 MCP admin_* 工具共用）：
  # <sort_key> desc + id desc 稳定决胜 + limit 封顶。MCP 工具无分页偏移，
  # 直接用本函数；web 侧带 offset 的走 paginate/3。
  # sort_key 默认 inserted_at；Reconciliation.Finding 按「最近出现」排（last_seen_at）。
  def recent(query, sort_key \\ :inserted_at, limit \\ 50) do
    query
    |> Ash.Query.sort([{sort_key, :desc}, {:id, :desc}])
    |> Ash.Query.limit(limit)
  end

  # search 模糊过滤（字段静态，search 运行时值经 ^ pin 注入）：
  # - maybe_user_search：email（ci_string）/ display_name contains OR
  # - maybe_workspace_search：name / slug contains OR
  def maybe_user_search(query, nil), do: query
  def maybe_user_search(query, ""), do: query

  def maybe_user_search(query, search) do
    Ash.Query.filter(
      query,
      contains(email, ^search) or contains(display_name, ^search)
    )
  end

  def maybe_workspace_search(query, nil), do: query
  def maybe_workspace_search(query, ""), do: query

  def maybe_workspace_search(query, search) do
    Ash.Query.filter(query, contains(name, ^search) or contains(slug, ^search))
  end

  # status 过滤（atom 约束字段；非枚举值静默忽略过滤——to_existing_atom 防 atom 表污染）。
  # field 参数化：WorkspaceApplication/PendingOperation 是 :status，ToolCallLog 是 :result_status。
  def maybe_status_filter(query, status, field \\ :status)

  def maybe_status_filter(query, nil, _field), do: query

  def maybe_status_filter(query, status, field) do
    case String.to_existing_atom(status) do
      # keyword 整体 ^ pin：字段名运行时化（宏模板内未 pin 变量会被当字段引用）
      atom -> Ash.Query.filter(query, ^[{field, atom}])
    end
  rescue
    ArgumentError -> query
  end

  # #117 PendingOperation 状态过滤：expired 不落库（读时派生 calculation，不能下推 SQL），
  # 特判为 status == :pending and expires_at < now（与 effective_status 同语义）；
  # 其余枚举值走通用 maybe_status_filter。
  def maybe_pending_status_filter(query, nil), do: query

  def maybe_pending_status_filter(query, "expired") do
    now = DateTime.utc_now()
    Ash.Query.filter(query, status == :pending and expires_at < ^now)
  end

  def maybe_pending_status_filter(query, status), do: maybe_status_filter(query, status)

  # #117 SignalLog 信号类型过滤（自由 string 精确匹配，如 "workflow.approval"；空串忽略）
  def maybe_signal_type_filter(query, nil), do: query
  def maybe_signal_type_filter(query, ""), do: query

  def maybe_signal_type_filter(query, signal_type) do
    Ash.Query.filter(query, signal_type == ^signal_type)
  end

  # #117 时间范围过滤（inserted_at）：inserted_after → >=，inserted_before → <=。
  # Absinthe :datetime 标量已把 ISO8601 解析为 DateTime；nil 分支不过滤。
  def maybe_time_range_filter(query, args) do
    query
    |> maybe_inserted_after(args[:inserted_after])
    |> maybe_inserted_before(args[:inserted_before])
  end

  defp maybe_inserted_after(query, nil), do: query

  defp maybe_inserted_after(query, dt) do
    Ash.Query.filter(query, inserted_at >= ^dt)
  end

  defp maybe_inserted_before(query, nil), do: query

  defp maybe_inserted_before(query, dt) do
    Ash.Query.filter(query, inserted_at <= ^dt)
  end

  # #116 action 过滤（AdminActionLog.action 是 atom 约束；非枚举值静默忽略过滤，
  # 与 maybe_status_filter 的 rescue 回退一致——to_existing_atom 防 atom 表污染）
  def maybe_action_filter(query, nil), do: query

  def maybe_action_filter(query, action) do
    case String.to_existing_atom(action) do
      atom -> Ash.Query.filter(query, action == ^atom)
    end
  rescue
    ArgumentError -> query
  end

  # D5：ToolCallLog / PendingOperation 的 workspace_id 在 params JSONB 内
  def maybe_workspace_filter(query, nil), do: query

  def maybe_workspace_filter(query, workspace_id) do
    # params->>'workspace_id' 是 JSONB text 提取，与 uuid 字符串比较。
    # 不显式调 expr/1（非宏函数无法处理 ^ pin）——filter/2 宏的 expression
    # 分支内部 require Ash.Expr 并解析 pin，故直接传 fragment 表达式。
    ws_id = to_string(workspace_id)
    Ash.Query.filter(query, fragment("params->>'workspace_id' = ?", ^ws_id))
  end

  # B1（advisor02）：SignalLog / WorkflowRun 有真实 workspace_id 列（非 params JSONB），
  # 用真实列过滤（区别于 maybe_workspace_filter 的 JSONB 版本）。
  def maybe_real_workspace_filter(query, nil), do: query

  def maybe_real_workspace_filter(query, workspace_id) do
    Ash.Query.filter(query, workspace_id == ^workspace_id)
  end

  # 分页：first 限条数（默认 50），after 为上一页已返回的条数（offset）。
  # offset 分页对 admin 内部列表足够（数据量有限），避免手写 keyset cursor
  # 的 datetime 解析复杂度；排序按 inserted_at+id 稳定。
  def paginate(query, first, after_offset) do
    query
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(first || 50)
    |> maybe_offset(after_offset)
  end

  defp maybe_offset(query, nil), do: query

  # B2（advisor02）：GraphQL arg(:after, :string) 声明为 string，Ash.Query.offset
  # 期望 integer——这里显式转换；非法值（非数字）回退忽略分页偏移。
  defp maybe_offset(query, offset) when is_integer(offset), do: Ash.Query.offset(query, offset)

  defp maybe_offset(query, offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {n, ""} when n >= 0 -> Ash.Query.offset(query, n)
      _ -> query
    end
  end
end
