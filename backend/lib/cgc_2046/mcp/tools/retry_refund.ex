defmodule Cgc2046.Mcp.Tools.RetryRefund do
  @moduledoc """
  重试退款：refund_failed → refunding 重入退款链（role-agent-journeys-v2 S3，
  Owner/Admin 管理工具，确认流 two-tool 写，D-D3）。

  语义对齐 GraphQL retryRefund（同 `Payments.Order :retry_refund` action，R17）：
  CAS refund_failed → refunding + 同事务入队渠道退款（PaymentRefundWorker）+
  `LogAdminAction` 审计留痕（action :order_refund_retry）。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  非 refund_failed 订单快速失败（不建 pending）；并发竞态由 domain 的 CAS 在
  confirm 段兜底。

  Owner/Admin 专属：默认 fail-closed member 门 + 工具层管理角色判定（第一段
  快速拒绝省 pending）；confirm 段由 retry_refund policy 兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  alias Cgc2046.Payments.Order

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:order_id, {:required, :string}, description: "待重试退款订单 ID（UUID，须为 refund_failed）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "retry_refund", fn actor, workspace_id, params ->
        order_id = params["order_id"] || params[:order_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, order} <- fetch_order(actor, workspace_id, order_id) do
          if order.status != :refund_failed do
            {:error, "仅 refund_failed 订单可重试退款（当前状态：#{order.status}）"}
          else
            summary =
              "重试退款订单 #{order.id}（金额 #{order.amount_cents} 分，渠道 #{order.provider}）：" <>
                "refund_failed → refunding 重入退款链；操作落审计（order_refund_retry）"

            Confirmation.request(
              frame.assigns[:current_user],
              "retry_refund",
              params,
              summary
            )
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  params 为 pending 落库的 redact 后参数（本工具参数无敏感键，直接可用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]
    order_id = params["order_id"]

    with {:ok, order} <- fetch_order(actor, workspace_id, order_id) do
      case order
           |> Ash.Changeset.for_update(:retry_refund, %{}, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, refunding} ->
          {:ok,
           %{
             order_id: refunding.id,
             status: to_string(refunding.status),
             enrollment_id: refunding.enrollment_id,
             amount_cents: refunding.amount_cents,
             provider: to_string(refunding.provider)
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or admin required to retry refunds in workspace #{workspace_id}"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to retry refund"}
      end
    end
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to retry refunds"}
    end
  end

  # tenant 收紧订单归属：他租户 order_id 与不存在同一「not found」，不泄露存在性
  defp fetch_order(actor, workspace_id, order_id) do
    case Ash.get(Order, order_id, actor: actor, tenant: workspace_id) do
      {:ok, nil} ->
        {:error, "order not found"}

      {:ok, order} ->
        {:ok, order}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read orders of workspace #{workspace_id}"}

      {:error, _} ->
        {:error, "failed to load order"}
    end
  end
end
