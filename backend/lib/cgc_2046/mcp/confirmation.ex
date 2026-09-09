defmodule Cgc2046.Mcp.Confirmation do
  @moduledoc """
  高风险操作确认流（D8 two-tool 模式 / D-D3）。

  链路（无 confirm 不落业务库）：

  1. 高风险操作的入口先调 `request/4`（不执行业务）：MCP 工具的 execute，
     或 web GraphQL mutation（经 `Cgc2046Web.PaymentConfirmation`，tool 名与
     对应 MCP 工具同名）——建 PendingOperation → 返回
     `{:needs_confirmation, %{pending_id, summary}}`
  2. 用户在客户端确认 → 确认入口（MCP `confirm_operation` 工具 / GraphQL
     `confirmOperation` mutation）→ `confirm/2`：
     校验 pending 归属/状态/有效期 → 标记 confirmed → 按 `pending.tool` 直接分派
     到对应工具的 `execute_confirmed/2` 真正落库
  3. 取消走 `cancel/2`（web 面对应 `cancelOperation` mutation）。

  确认后的 effect 分派见私有 `execute/3`：从组件注册表派生
  （`Wrapper.executor_for/1`，name → 导出 `execute_confirmed/2` 的 handler module）。
  """

  alias Cgc2046.Mcp.PendingOperation
  alias Cgc2046.Mcp.Wrapper

  require Logger

  @doc """
  为高风险工具建 pending 并返回 needs_confirmation（不落业务库）。

  `summary_fun` 由 tool 提供人类可读摘要（展示给用户确认）。
  """
  @spec request(term(), String.t(), map(), String.t()) ::
          {:needs_confirmation, %{pending_id: String.t(), summary: String.t()}}
          | {:error, String.t()}
  def request(actor, tool_name, params, summary) do
    # PendingOperation.params 是 two-tool 事务数据（confirm 时原样喂给
    # execute_confirmed/2 落业务库），**必须落完整 params**——Redact 脱敏/截断
    # 只作用于审计路径（ToolCallLog，由 Wrapper 落行时处理）。在此脱敏会把
    # ">1KB reason 被截断 → 确认执行拿到残缺的 payload"这类死锁引进来，
    # 敏感键替换同理（"token" 命名参数被换成 "[REDACTED]" 后执行即坏）。
    case PendingOperation
         |> Ash.Changeset.for_create(
           :pend,
           %{
             user_id: actor.id,
             tool: tool_name,
             params: params,
             summary: summary
           },
           authorize?: false
         )
         |> Ash.create() do
      {:ok, op} ->
        {:needs_confirmation, %{pending_id: op.id, summary: summary}}

      {:error, error} ->
        Logger.error("[Mcp.Confirmation] pend failed: #{inspect(error)}")
        {:error, "failed to create pending operation"}
    end
  end

  @doc """
  确认并执行 pending 操作。仅本人、pending 且未过期可确认。

  返回 `{:ok, %{pending_id, status: "confirmed", result: map()}}`，
  其中 `result` 为 `execute/3` 分派到对应工具 `execute_confirmed/2` 的业务结果。
  """
  @spec confirm(term(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def confirm(actor, pending_id) do
    with {:ok, op} <- fetch_own(actor, pending_id),
         {:ok, confirmed} <- mark_confirmed(op, actor) do
      case execute(confirmed.tool, actor, confirmed.params) do
        {:ok, result} ->
          {:ok, %{pending_id: confirmed.id, status: "confirmed", result: result}}

        {:error, msg} ->
          # MEDIUM-2 / MEDIUM-3：effect 失败不留 confirmed-but-no-effect——回滚到 pending
          # 让用户可重试。若 pending 已过期，回滚后 effective_status 读时派生为 expired，
          # confirm 的过期预检仍会拒绝，状态机语义保持一致。
          revert_to_pending(confirmed)
          {:error, msg}
      end
    end
  end

  @doc """
  取消 pending 操作（仅本人、pending）。
  """
  @spec cancel(term(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def cancel(actor, pending_id) do
    with {:ok, op} <- fetch_own(actor, pending_id),
         {:ok, cancelled} <-
           op |> Ash.Changeset.for_update(:cancel, %{}, actor: actor) |> Ash.update() do
      {:ok, %{pending_id: cancelled.id, status: "cancelled"}}
    else
      {:error, %Ash.Error.Invalid{} = err} -> {:error, Exception.message(err)}
      other -> other
    end
  end

  # ---------------------------------------------------------------------------
  # 确认流错误 code 契约单源（#241 四清单机械联动）。
  #
  # code 必须在 domain 层显式出现——`ErrorCodeContract` 只扫 lib/cgc_2046/**，
  # web GraphQL 面（graphql_schema.ex / PaymentConfirmation）不得自造 code，
  # 否则 web messages 的文案键不在 priv/error_codes_contract.json 中，contract
  # test 红灯。AST 扫描收 `code: "literal"` 形态（见 collect/2）。
  # ---------------------------------------------------------------------------
  @confirm_failed %{code: "operation_confirm_failed"}
  @cancel_failed %{code: "operation_cancel_failed"}
  @unavailable %{code: "operation_unavailable"}

  @doc "confirm/2 失败的契约 code（不存在/非本人/已过期/effect 失败）"
  @spec confirm_failed_code() :: String.t()
  def confirm_failed_code, do: @confirm_failed.code

  @doc "cancel/2 失败的契约 code（不存在/非本人/非 pending）"
  @spec cancel_failed_code() :: String.t()
  def cancel_failed_code, do: @cancel_failed.code

  @doc "request/4 失败的契约 code（pending 建不起来）"
  @spec unavailable_code() :: String.t()
  def unavailable_code, do: @unavailable.code

  defp fetch_own(actor, pending_id) do
    case Ash.get(PendingOperation, pending_id, authorize?: false) do
      {:ok, nil} ->
        {:error, "pending operation not found"}

      {:ok, %PendingOperation{user_id: user_id}} when user_id != actor.id ->
        # 他人 pending 与不存在同等处理，不泄露存在性
        {:error, "pending operation not found"}

      {:ok, op} ->
        {:ok, op}

      {:error, _} ->
        {:error, "failed to load pending operation"}
    end
  end

  defp mark_confirmed(op, actor) do
    case op |> Ash.Changeset.for_update(:confirm, %{}, actor: actor) |> Ash.update() do
      {:ok, confirmed} ->
        {:ok, confirmed}

      {:error, %Ash.Error.Invalid{} = err} ->
        {:error, Exception.message(err)}

      # 并发双确认：DB 条件更新未命中（已被另一请求确认）→ 友好错误（MEDIUM-1）
      {:error, %Ash.Error.Changes.StaleRecord{}} ->
        {:error, "Operation is not pending (concurrent confirmation won)"}

      {:error, _} ->
        {:error, "failed to confirm operation"}
    end
  end

  defp revert_to_pending(confirmed) do
    case confirmed
         |> Ash.Changeset.for_update(:revert_to_pending, %{}, authorize?: false)
         |> Ash.update() do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error(
          "[Mcp.Confirmation] revert_to_pending failed for #{confirmed.id}: #{inspect(error)}"
        )

        :ok
    end
  end

  # 确认后的 effect 分派派生自组件注册表（`Wrapper.executor_for/1`）：工具导出
  # `execute_confirmed/2` 即可被分派，无第二注册点。兜底覆盖数据异常
  # （pending.tool 指向已下线/未注册工具），不泄露 params/actor 结构。
  defp execute(tool_name, actor, params) do
    case Wrapper.executor_for(tool_name) do
      {:ok, module} -> module.execute_confirmed(actor, params)
      :error -> {:error, "no executor for tool #{tool_name}"}
    end
  end
end
