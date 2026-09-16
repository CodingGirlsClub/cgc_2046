defmodule Cgc2046.Mcp.Errors do
  @moduledoc """
  MCP 错误出口统一收口（#612）。

  `lib/cgc_2046/mcp/` 下**唯一**允许把错误树转成调用方可见字符串的地方：工具、
  确认流、审计写入一律经本模块，不再直接 `Exception.message/1` 或 `inspect/1`
  错误树——该纪律由 `test/cgc_2046/mcp/error_egress_guard_test.exs` 结构守卫
  钉死（新增工具漏走本模块会红灯，而不是静默带洞）。

  判定顺序（第 1/3 条与 #612 逐字一致；第 2 条经 #631 折叠化，见下）：

  1. `Cgc2046.Errors.DatabaseError.unmapped?/1` → `database_error: … (error id: <uuid>)`
     （原文只进服务端日志，见 `DatabaseError.report/1`）；
  2. 已知 `%Ash.Error.Invalid{}` → **逐叶折叠**（Ash 原序、`", "` 分隔）：类头
     （`Invalid Error`）、共享/逐叶 `Bread Crumbs:`、逐叶 `path/1` 与 stacktrace
     **不再出面**（#631）。折叠前的行为是 `Exception.message/1` 直出整条类消息，
     `save_course_content`（8 行）与 `confirm_operation`（1 行）的负面可读性即此
     （PR #637 的 dev 普查同形：Ash 类 message 形状 13 行）；
  3. 其余 → 调用点自带的 fallback 文案，与改动前 `{:error, _} ->` 分支逐字一致。

  逐字一致性的**唯一例外**（有意，评审 F1）：`submit_learning_attempt` 改动前的
  fallback 不是字面量，而是把 `inspect/1` 的结果拼在 `"failed to record learning
  attempt: "` 之后——`inspect/1` 一颗未知错误树正会打出原始库内文本，所以该处统一
  为字面量 `"failed to record learning attempt"`；其已知 `%Ash.Error.Invalid{}`
  路径不受影响（仍是逐叶折叠）。其余 37 个调用点的 fallback 字面量逐字未动。

  混合树（`%Ash.Error.Invalid{}` 内同时含已映射叶子与未知叶子）在 MCP 面**整条**
  降级为 `database_error: …`（已映射叶子的文案不再单列）；GraphQL 面按叶子逐个
  映射、已映射叶子保留自己的 code/message（`AshGraphql.Graphql.Resolver.
  unwrap_errors/1` 展开后逐个查 impl）。纯已映射错误两面都逐字不变。

  审计列（`ToolCallLog.error_message`）走 `audit_message/1`：该列经
  `admin_list_audit_logs`（MCP）、`list_tool_call_logs` /
  `my_workspace_tool_calls`（GraphQL）与 AshAdmin 二次读出，是真实暴露面
  （`Redact` 只洗 `params`，不洗错误文本），故**任何**非二进制错误一律落固定摘要
  + uuid，原文只进服务端日志——未映射 → `database_error: …`，其余 →
  `internal error (error id: <uuid>)`。
  """

  alias Cgc2046.Errors.DatabaseError

  @doc """
  错误 → 调用方可见字符串。

  `fallback` 为「非未映射且非 Invalid」时的原文案，与调用点改动前
  `{:error, _} ->` 分支逐字一致。

  已是字符串的错误原样透传（下游 `with/else` 分支里 `{:error, message}` 的
  既有直通语义不因本模块收口而改变）。
  """
  @spec message(term, String.t()) :: String.t()
  def message(error, _fallback) when is_binary(error), do: error

  # 已知 `%Ash.Error.Invalid{}`（Splode 错误类）→ **逐叶折叠**（#631）：类消息
  # （`Exception.message/1`）会渲染 "Bread Crumbs:" + "Invalid Error" + 逐叶 path 与
  # stacktrace——那是给开发者的，调用方只需要叶子文案。
  #
  # 两道剥壳，缺一不可（实测）：
  #  1. 类头：不再走 `Exception.message/1` 的错误类渲染（`Splode.ErrorClass`）；
  #  2. **叶子的 bread_crumbs**：Splode 在 `__before_compile__` 里把面包屑前置进
  #     每个叶子自己的 message（`bread_crumb(bread_crumbs) <> "\n" <> message`），
  #     所以逐叶渲染前必须清空该字段——否则 "Bread Crumbs: > Error returned from:
  #     <模块>.<action>" 照样出面（生产 `save_course_content` 的行正是这种带
  #     breadcrumbs 的叶子）。
  #
  # 逐叶拼接沿用既有列表分支的格式（Ash 原序、", " 分隔）。含未映射叶子时整条降级为
  # `database_error: … (error id: …)`（委托 `safe_message/2` 的列表分支；`unmapped?/1`
  # 对类做 `Enum.any?`），与「混合树整条降级」的既有口径一致。
  def message(%Ash.Error.Invalid{errors: errors}, fallback) when is_list(errors) do
    if DatabaseError.unmapped?(errors) do
      DatabaseError.safe_message(errors, fallback)
    else
      case errors |> Enum.map(&leaf_message/1) |> Enum.reject(&(&1 == "")) |> Enum.join(", ") do
        "" -> fallback
        text -> text
      end
    end
  end

  def message(error, fallback) do
    if DatabaseError.unmapped?(error) do
      DatabaseError.safe_message(error)
    else
      fallback
    end
  end

  defp leaf_message(leaf) when is_binary(leaf), do: leaf

  defp leaf_message(leaf) do
    leaf =
      if is_struct(leaf) and Map.has_key?(leaf, :bread_crumbs) do
        %{leaf | bread_crumbs: []}
      else
        leaf
      end

    Exception.message(leaf)
  end

  @doc """
  审计列（`ToolCallLog.error_message`）取值——**永不**落错误原文。

  该列会被二次读出（MCP `admin_list_audit_logs`；GraphQL `list_tool_call_logs`
  / `my_workspace_tool_calls`；AshAdmin），且 `Cgc2046.Mcp.Redact` 只洗 `params`
  不洗错误文本，所以这里按两条固定摘要收口：

  - 未映射错误 → `database_error: … (error id: <uuid>)`（与调用方拿到的同一口径）；
  - **其余**非二进制错误 → `internal error (error id: <uuid>)`，原文只进服务端
    日志。`inspect/1` 被彻底移除：裸 `%Postgrex.Error{}` / `%Ecto.ConstraintError{}`
    或带 `private_vars.detail` 的已映射错误，inspect 都会打出约束名 / 表名 /
    `Key (x)=(y) already exists.` / SQL 片段。
  """
  @spec audit_message(term) :: String.t()
  def audit_message(error) do
    if DatabaseError.unmapped?(error) do
      DatabaseError.mcp_error(error)
    else
      DatabaseError.internal_summary(error)
    end
  end
end
