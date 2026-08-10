defmodule Cgc2046.Mcp.Confirmation do
  @moduledoc """
  高风险工具确认流（D8 two-tool 模式 / D-D3）。

  链路（无 confirm 不落业务库）：

  1. 高风险 tool 的 execute 先调 `request/4`（不执行业务）：
     建 PendingOperation → 返回 `{:needs_confirmation, %{pending_id, summary}}`
  2. 用户在客户端确认 → agent 调 `confirm_operation` tool → `confirm/2`：
     校验 pending 归属/状态/有效期 → 标记 confirmed → 按 `pending.tool` 直接分派
     到对应工具的 `execute_confirmed/2` 真正落库
  3. 取消走 `cancel/2`。

  确认后的 effect 分派见私有 `execute/3`：每个高风险工具一个函数子句，
  调用该工具自身的 `execute_confirmed/2`；新增高风险工具时加一个 `execute/3` 子句。
  """

  alias Cgc2046.Mcp.PendingOperation

  require Logger

  @doc """
  为高风险工具建 pending 并返回 needs_confirmation（不落业务库）。

  `summary_fun` 由 tool 提供人类可读摘要（展示给用户确认）。
  """
  @spec request(term(), String.t(), map(), String.t()) ::
          {:needs_confirmation, %{pending_id: String.t(), summary: String.t()}}
          | {:error, String.t()}
  def request(actor, tool_name, params, summary) do
    case PendingOperation
         |> Ash.Changeset.for_create(
           :pend,
           %{
             user_id: actor.id,
             tool: tool_name,
             params: Cgc2046.Mcp.Redact.call(params),
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

  # 确认后的 effect 直接分派：Confirmation 直接持有每个工具的确认执行知识。
  # 新增高风险工具时加一个子句，调用该工具自身的 execute_confirmed/2。
  defp execute("create_invitation", actor, params) do
    Cgc2046.Mcp.Tools.CreateInvitation.execute_confirmed(actor, params)
  end

  # fallback：防御性处理未知 tool（理论上 request 写入的 tool 名与分派覆盖一致，
  # 但数据异常时不泄露 params/actor 结构）
  defp execute(tool, _actor, _params) do
    {:error, "no executor for tool #{tool}"}
  end
end
