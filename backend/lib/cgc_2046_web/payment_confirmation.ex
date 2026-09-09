defmodule Cgc2046Web.PaymentConfirmation do
  @moduledoc """
  Web GraphQL 高风险支付操作的两段确认编排（refundOrder / retryRefund /
  waivePayment，R15/R17/R18）。

  与 MCP 工具复用同一确认机制（`Cgc2046.Mcp.Confirmation` + PendingOperation）：
  pending 的 `tool` 与对应 MCP 工具同名，confirm 段经 `Wrapper.executor_for/1`
  分派到该工具的 `execute_confirmed/2`——domain action 的 CAS、
  `LogAdminAction` 审计与退款 worker 入队路径不变，仅多一层确认门。

  1. 第一段（本模块 `request_*`，GraphQL mutation 同名入口）：actor 读权取
     目标记录 → 管理权预检（本工作台 Owner/Admin 或 platform_admin，与 domain
     policy 同语义，第一段快速拒绝省脏 pending）→ 状态快速失败 → 建
     PendingOperation（不落业务库）→ 返回 `%{pending_id, summary}`（摘要
     后端生成，确认弹层只透传）。
  2. 第二段（`confirmOperation`/`cancelOperation`，graphql_schema.ex 手写
     mutation）：直通 `Confirmation.confirm/cancel`（仅本人、pending 且未
     过期；effect 失败回滚 pending 可重试）。

  本工作台 Owner/Admin 与跨租户 platform_admin 一律两段：与 MCP 确认流同
  语义，资金类破坏操作不留单段直执旁路（platform_admin 跨租户强制是底线）。
  """

  alias Cgc2046.Accounts.Policies.PlatformAdmin
  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Payments.Order

  @type error :: %{message: String.t(), code: String.t()}
  @type pending :: %{pending_id: String.t(), summary: String.t()}

  @doc "refundOrder 第一段：paid 订单建退款 pending（不落业务库）。"
  @spec request_refund(term(), String.t()) :: {:ok, pending()} | {:error, error()}
  def request_refund(actor, order_id) do
    with {:ok, order} <- fetch(Order, actor, order_id),
         :ok <- authorize_manage(actor, order.workspace_id),
         :ok <- ensure_status(order.status, :paid, "order_already_processed") do
      request(
        actor,
        "refund_order",
        %{"workspace_id" => order.workspace_id, "order_id" => order.id},
        "退款 #{yuan(order.amount_cents)}（渠道 #{order.provider}）：paid → refunding " <>
          "并入队渠道退款，原路全额退回；退款即取消报名并释放名额，此操作不可恢复"
      )
    end
  end

  @doc "retryRefund 第一段：refund_failed 订单建重试 pending（不落业务库）。"
  @spec request_retry_refund(term(), String.t()) :: {:ok, pending()} | {:error, error()}
  def request_retry_refund(actor, order_id) do
    with {:ok, order} <- fetch(Order, actor, order_id),
         :ok <- authorize_manage(actor, order.workspace_id),
         :ok <- ensure_status(order.status, :refund_failed, "order_already_processed") do
      request(
        actor,
        "retry_refund",
        %{"workspace_id" => order.workspace_id, "order_id" => order.id},
        "重试退款 #{yuan(order.amount_cents)}（渠道 #{order.provider}）：refund_failed → " <>
          "refunding，重新入队渠道退款；确认后真正向渠道发起退回"
      )
    end
  end

  @doc "waivePayment 第一段：payment_pending 报名建免缴 pending（不落业务库）。"
  @spec request_waive(term(), String.t()) :: {:ok, pending()} | {:error, error()}
  def request_waive(actor, enrollment_id) do
    with {:ok, enrollment} <- fetch(Enrollment, actor, enrollment_id),
         :ok <- authorize_manage(actor, enrollment.workspace_id),
         :ok <-
           ensure_status(
             enrollment.status,
             :payment_pending,
             "enrollment_not_payment_pending"
           ) do
      request(
        actor,
        "waive_payment",
        %{"workspace_id" => enrollment.workspace_id, "enrollment_id" => enrollment.id},
        "免缴该报名：跳过支付直接确认（payment_pending → confirmed），" <>
          "关联待支付订单将同事务作废；操作落审计且不可撤销"
      )
    end
  end

  # 读权即第一道理前门（读 policy：报名人本人 / Owner/Admin / PlatformAdmin）；
  # 无权/不存在/非法 id 同塌缩为 not_found，不泄露存在性
  defp fetch(resource, actor, id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, record} <- Ash.get(resource, id, actor: actor) do
      if record, do: {:ok, record}, else: {:error, not_found()}
    else
      _ -> {:error, not_found()}
    end
  end

  # 管理权预检（与 domain policy 同语义：WorkspaceActorIsOwnerOrAdmin +
  # PlatformAdmin）；confirm 段由 domain policy 兜底
  defp authorize_manage(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) or PlatformAdmin.platform_admin?(actor) do
      :ok
    else
      {:error, %{message: "forbidden: owner or admin required", code: "forbidden"}}
    end
  end

  # 状态快速失败（不建脏 pending）；code/message 与 domain CAS 错误同契约
  # （前端按 code 查文案），并发竞态仍由 confirm 段的 domain CAS 兜底
  defp ensure_status(actual, expected, code) do
    if actual == expected do
      :ok
    else
      {:error, %{message: domain_status_message(code), code: code}}
    end
  end

  defp domain_status_message("order_already_processed"), do: "order has already been processed"

  defp domain_status_message("enrollment_not_payment_pending"),
    do: "enrollment is not awaiting payment"

  defp request(actor, tool, params, summary) do
    case Confirmation.request(actor, tool, params, summary) do
      {:needs_confirmation, %{pending_id: pending_id, summary: summary}} ->
        {:ok, %{pending_id: pending_id, summary: summary}}

      {:error, message} ->
        {:error, %{message: message, code: Confirmation.unavailable_code()}}
    end
  end

  defp not_found, do: %{message: "could not be found", code: "not_found"}

  # 金额分 → ¥ 字符串（div/rem 精确格式化，不走浮点）
  defp yuan(amount_cents) do
    "¥#{div(amount_cents, 100)}.#{amount_cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
