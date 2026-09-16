defmodule Cgc2046.Errors.DatabaseError do
  @moduledoc """
  未映射错误的全局安全网（#612，路线 C）。

  Ash 的未知类错误在 ash_graphql 侧**没有** `AshGraphql.Error` impl，落到
  `AshGraphql.Errors.to_errors/6` 的 else 分支，退化成「something went wrong.
  Unique error id: <uuid>」——用户与前端都拿不到稳定 code；MCP 面则把
  `Exception.message/1` 的原文（索引名 / 约束名 / 表名 / SQL 片段 / 冲突键值）
  直出给调用方。

  本模块是**唯一判据与唯一文案出口**：

  - `unmapped?/1` 只认错误类（`Ash.Error.Unknown` 类、它的叶子
    `Ash.Error.Unknown.UnknownError`，以及任意深度嵌套——含嵌套在
    `Ash.Error.Invalid` 里的混合树），**不认约束类型**：与
    `Cgc2046.Errors.ConstraintConflict` 的 fail-closed 判据
    （`private_vars.constraint_type`）正交，不扩大其判据面；
  - `report/1` 生成 uuid 并把**原文只写进服务端日志**（同级 `error_id=` 可
    grep 对照），返回给两个面的只有 `database operation failed (error id: …)`；
  - `graphql_error/1` / `mcp_error/1` 给出 GraphQL 与 MCP 两个面的形状，code
    复用 #241 既有契约条目 `database_error`（不新增）。

  判据为何要覆盖类**与**叶子（实测，非推测）：`Ash.Error.to_ash_error/2` 对
  `%Postgrex.Error{}` 一类异常返回的是**叶子** `UnknownError`；类只在
  `Ash.Error.to_error_class/2` 归并后出现（单一未知错误 → `Ash.Error.Unknown`
  类；与 invalid 类错误混合 → `Ash.Error.Invalid` 类）。而
  `AshGraphql.Graphql.Resolver.unwrap_errors/1` 会展开 `Ash.Error.Invalid`，
  故混合树到面的是叶子。叶子 impl 同时是「ash_graphql 升版改了
  `unwrap_errors` 展开规则」的冗余兜底。

  日志边界（#612 验收）：`Exception.format/2,3` 的完整原文（含库内标识与
  conflict detail）**只出现在服务端日志**；GraphQL / MCP / 审计列一律只有
  uuid。
  """

  require Logger

  @code "database_error"
  # 与既有同 code 生产者（order / enrollment / sponsorship / attendance /
  # speaker_invitation / moderator_membership_validation）逐字一致：
  # 同 code 同文案，零回归。
  @message "database operation failed"

  @type report :: %{uuid: String.t(), text: String.t()}

  @doc "契约 code（`priv/error_codes_contract.json` 既有条目，不新增）。"
  @spec code() :: String.t()
  def code, do: @code

  @doc "两面共用的用户可见文案基句（uuid 后缀由 `report/1` 拼）。"
  @spec message() :: String.t()
  def message, do: @message

  @doc """
  是否未映射错误（Unknown 类 / 其叶子，含任意深度嵌套）。

  只按**错误类**判定；DB 真故障与「未声明约束的冲突」同桶，这正是路线 C 的
  全局安全网口径（逐资源配码是 #611 的事）。
  """
  @spec unmapped?(term) :: boolean
  def unmapped?(%Ash.Error.Unknown{}), do: true
  def unmapped?(%Ash.Error.Unknown.UnknownError{}), do: true

  def unmapped?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &unmapped?/1)

  def unmapped?(errors) when is_list(errors), do: Enum.any?(errors, &unmapped?/1)

  def unmapped?(_error), do: false

  @doc """
  生成可日志关联的 uuid，并把原文写进服务端日志。

  日志一行，`error_id=<uuid>` 与面上 message 里的 uuid 同名，可双向对照定位。
  """
  @spec report(term) :: report
  def report(error) do
    uuid = log_raw(error, "database_error")
    %{uuid: uuid, text: "#{@message} (error id: #{uuid})"}
  end

  @doc """
  审计列专用固定摘要：**非**未映射的非二进制错误（如裸 `%Postgrex.Error{}` /
  `%Ecto.ConstraintError{}` / 带 `private_vars.detail` 的已映射错误）→
  `internal error (error id: <uuid>)`。

  为什么固定摘要而不是 `inspect/1`：`ToolCallLog.error_message` 会被
  `admin_list_audit_logs`（MCP）/ `list_tool_call_logs` / `my_workspace_tool_calls`
  （GraphQL）与 AshAdmin 二次读出，属真实暴露面；`inspect/1` 一颗 Postgrex/Ecto
  错误会打出约束名、表名、`detail: Key (x)=(y) already exists.` 与 SQL 片段。
  原文只进服务端日志（`[internal_error] error_id=…`），uuid 供对照定位。
  """
  @spec internal_summary(term) :: String.t()
  def internal_summary(error) do
    uuid = log_raw(error, "internal_error")
    "internal error (error id: #{uuid})"
  end

  @doc "GraphQL 面形状（`AshGraphql.Error.to_error/1` 返回值）。"
  @spec graphql_error(term) :: map
  def graphql_error(error) do
    %{text: text} = report(error)

    %{
      message: text,
      short_message: @code,
      code: @code,
      vars: %{},
      fields: []
    }
  end

  @doc "MCP 面形状：`database_error: …` 前缀，口径同既有 `forbidden: …`。"
  @spec mcp_error(term) :: String.t()
  def mcp_error(error) do
    %{text: text} = report(error)
    "#{@code}: #{text}"
  end

  @doc """
  错误（树 / 列表 / 任意）→ 安全字符串（domain 侧共享层出口）。

  - 含未映射错误（未知类，含嵌套与混合树）→ `database_error: … (error id: …)`，
    原文只进服务端日志；
  - 列表（Ash changeset errors）→ 逐条 `Exception.message/1` 拼接，原口径不变；
  - 其余：给了 `fallback` 就用 fallback（调用点改动前的兜底文案），没给则是已
    知异常/二进制原文。

  仅供 domain 共享层（`Curriculum.Prep` / `Courses.Course` 等）在**不经过 MCP
  出口模块**时使用；MCP 面统一走 `Cgc2046.Mcp.Errors.message/2`。
  """
  @spec safe_message(term, String.t() | nil) :: String.t()
  def safe_message(error, fallback \\ nil)

  def safe_message(errors, _fallback) when is_list(errors) do
    case Enum.find(errors, &unmapped?/1) do
      nil -> Enum.map_join(errors, ", ", &Exception.message/1)
      error -> mcp_error(error)
    end
  end

  def safe_message(error, fallback) do
    cond do
      unmapped?(error) -> mcp_error(error)
      is_binary(error) -> error
      is_binary(fallback) -> fallback
      is_exception(error) -> Exception.message(error)
      true -> inspect(error)
    end
  end

  defp log_raw(error, label) do
    uuid = Ash.UUID.generate()
    Logger.error("[#{label}] error_id=#{uuid} " <> format_raw(error))
    uuid
  end

  defp format_raw(error) when is_exception(error) do
    case error do
      %{stacktrace: %{stacktrace: stacktrace}} when is_list(stacktrace) ->
        Exception.format(:error, error, stacktrace)

      _ ->
        Exception.format(:error, error)
    end
  end

  defp format_raw(error), do: "unmapped error: #{inspect(error)}"
end
