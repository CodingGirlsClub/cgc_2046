defmodule Cgc2046.Mcp.Wrapper do
  @moduledoc """
  MCP 工具调用的统一封装（D-D7 / D-D8 / D9）。

  每个 tool 的 `execute/2` 入口都经 `run/3`：

  1. 从 frame.assigns 取 actor（McpAuthPlug 注入 `:current_user`）
  2. 校验必填 `workspace_id`（D12 无状态作用域；可豁免的工具见 @workspace_optional）
  3. membership 鉴权：非成员直接 Forbidden（不经业务 action，快速拒绝）
  4. 执行业务 fun（`fn actor, workspace_id, params -> {:ok, result} | {:error, msg} end`）
  5. 落 ToolCallLog 审计（ok / error / forbidden；失败不阻塞响应，记 Logger）

  确认流工具（D-D3 two-tool）不在此处理 `needs_confirmation`——由
  `Cgc2046.Mcp.Confirmation.request/4` 先行拦截，本模块只负责审计与鉴权。
  """

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Mcp.Redact
  alias Cgc2046.Mcp.ToolCallLog

  require Logger

  # 不需要 workspace 成员资格的内置工具（确认流承载 tool，鉴权在 Confirmation 内做）
  @workspace_optional ~w(confirm_operation cancel_operation)

  # 成员资格检查**下沉**到工具自身授权的工具（E-7 #122）：save_step_output 对
  # learning run 放行「报名学员本人」（非成员，授权来自 Enrollment 记录本身，
  # 设计 §4.1）——成员门槛若在 Wrapper 层拦截，学员永远到不了工具层判定。
  # 下沉不等于放开：工具内仍有 StepAuthorization 判定 + 资源层 Ash policy 双重门禁。
  @membership_deferred ~w(save_step_output)

  @type result ::
          {:ok, map() | String.t()}
          | {:error, String.t()}
          | {:needs_confirmation, %{pending_id: String.t(), summary: String.t()}}

  @doc """
  执行一个工具调用。`fun` 签名为 `(actor, workspace_id | nil, params) -> result`。
  """
  @spec run(map(), map(), String.t(), fun()) :: result()
  def run(frame, params, tool_name, fun) do
    started = System.monotonic_time(:millisecond)
    actor = frame.assigns[:current_user]
    workspace_id = params["workspace_id"] || params[:workspace_id]

    result =
      with :ok <- check_actor(actor),
           :ok <- check_workspace_id(tool_name, workspace_id),
           :ok <- check_membership(tool_name, actor, workspace_id) do
        fun.(actor, workspace_id, params)
      end

    log_call(actor, tool_name, params, result, System.monotonic_time(:millisecond) - started)

    result
  end

  @doc false
  def workspace_optional?(tool_name), do: tool_name in @workspace_optional

  defp check_actor(nil), do: {:error, "unauthenticated: valid MCP connection token required"}
  defp check_actor(_actor), do: :ok

  defp check_workspace_id(tool_name, workspace_id) do
    if workspace_optional?(tool_name) or is_binary(workspace_id) do
      :ok
    else
      {:error, "forbidden: workspace_id is required for tool #{tool_name} (D12 stateless scope)"}
    end
  end

  defp check_membership(tool_name, actor, workspace_id) do
    cond do
      workspace_optional?(tool_name) ->
        :ok

      tool_name in @membership_deferred ->
        # 成员门槛由工具层授权判定替代（见 @membership_deferred 注释）
        :ok

      true ->
        case MembershipContext.membership_of(actor, workspace_id) do
          nil -> {:error, "forbidden: not a member of workspace #{workspace_id}"}
          _membership -> :ok
        end
    end
  end

  # 审计落库失败不阻塞工具响应（审计可用性 < 工具可用性），但记 error 日志留痕
  defp log_call(nil, _tool, _params, _result, _latency), do: :ok

  defp log_call(actor, tool_name, params, result, latency_ms) do
    {status, error_message, pending_id} = classify(result)

    ToolCallLog
    |> Ash.Changeset.for_create(
      :log,
      %{
        user_id: actor.id,
        tool: tool_name,
        params: Redact.call(params || %{}),
        result_status: status,
        error_message: error_message && String.slice(error_message, 0, 500),
        latency_ms: latency_ms,
        pending_operation_id: pending_id
      },
      authorize?: false
    )
    |> Ash.create()
    |> case do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("[Mcp.Wrapper] ToolCallLog write failed for #{tool_name}: #{inspect(error)}")
        :ok
    end
  end

  defp classify({:ok, _}), do: {:ok, nil, nil}
  defp classify({:error, msg}) when is_binary(msg), do: classify_error(msg)
  defp classify({:error, err}), do: {:error, inspect(err) |> String.slice(0, 500), nil}

  defp classify({:needs_confirmation, %{pending_id: pending_id}}),
    do: {:needs_confirmation, nil, pending_id}

  defp classify_error(msg) do
    if String.starts_with?(msg, "forbidden") do
      {:forbidden, msg, nil}
    else
      {:error, msg, nil}
    end
  end
end
