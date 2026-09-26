defmodule Cgc2046.Mcp.Tools.UnforfeitOrder do
  @moduledoc """
  错没收补救：forfeited → refunding 重入退款链（#545 押金制运营安全网）。

  语义 = `Payments.Order :unforfeit` action：CAS forfeited → refunding + 同事务
  入队渠道退款（PaymentRefundWorker，与 refund 同链、查单幂等不重复退）+
  `LogAdminAction` 审计留痕（action :order_unforfeit，metadata 含必填 reason）。

  **仅平台管理员**（issue #545 拍板，meta 门控族 `:platform_admin`）：没收是
  平台裁决，推翻同权——工作台 Owner/Admin 不持此权限（与 refund_order /
  retry_refund 的管理角色门区分）。confirm 段由 unforfeit policy 的
  `Policies.PlatformAdmin` 兜底。

  两次调用（two-tool 确认流，D-D3）：第一次不落业务库，建 PendingOperation
  返回 needs_confirmation（摘要含订单种类/金额/理由）；确认后真正执行。
  非 forfeited 订单快速失败（不建 pending）；并发竞态由域 CAS 在 confirm 段
  兜底（order_already_processed）。

  覆盖场景：迟到场（no-show 结算后参与者携正当理由到场）、ends_at 误改又
  修回导致的错没收、参与者有正当理由未到场经运营人工核实。
  """

  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  alias Cgc2046.Payments.Order

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    平台管理员专用（工作台 Owner/Admin 不能用）：补救被错误没收的押金单，把已没收（forfeited）的押金重新
    退款。适用于迟到但有正当理由、结束时间误改导致误没收、人工核实过的正当缺席等情况。reason 必填（1–500
    字，写明错没收的事实与核实依据，记入审计）。确认摘要含订单种类、金额和理由。订单不是 forfeited 时直接
    返回错误。
    走确认流：第一次调用只返回 needs_confirmation + pending_id + summary，
    用户确认后调 confirm_operation(pending_id) 才执行。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "押金单所属工作台 ID（UUID，须与订单归属一致）")

    field(:order_id, {:required, :string}, description: "待补救的押金单 ID（UUID，须为 forfeited 终态）")

    field(:reason, {:required, :string}, description: "补救理由（必填，1-500 字，落审计：错没收事实 + 人工核实依据）")
  end

  @impl true
  def execute(params, frame) do
    # reason 属补救依据（非自由文本敏感面），落 ToolCallLog.params 无审计红线；
    # PendingOperation.params 必须落完整值（confirm 段执行依赖，Confirmation
    # 模块级注释的单点纪律），此处不摘除。
    result =
      Wrapper.run(frame, params, "unforfeit_order", fn actor, workspace_id, params ->
        order_id = params["order_id"]
        reason = params["reason"]

        with :ok <- validate_reason(reason),
             {:ok, order} <- fetch_order(actor, workspace_id, order_id) do
          if order.status != :forfeited do
            {:error, "仅 forfeited（已没收）押金单可补救（当前状态：#{order.status}）"}
          else
            kind_label = if order.order_kind == :deposit, do: "押金单", else: "报名单"

            summary =
              "补救退#{kind_label} #{order.id}（金额 #{order.amount_cents} 分，渠道 #{order.provider}）：" <>
                "forfeited → refunding 原路全额退回；理由：#{reason}；操作落审计（order_unforfeit）"

            Confirmation.request(
              frame.assigns[:current_user],
              "unforfeit_order",
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
  params 为 pending 落库的完整参数（reason 为执行依赖，不脱敏）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]
    order_id = params["order_id"]

    with {:ok, order} <- fetch_order(actor, workspace_id, order_id) do
      case order
           |> Ash.Changeset.for_update(:unforfeit, %{reason: params["reason"]},
             tenant: workspace_id
           )
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, refunding} ->
          {:ok,
           %{
             order_id: refunding.id,
             order_kind: to_string(refunding.order_kind),
             status: to_string(refunding.status),
             enrollment_id: refunding.enrollment_id,
             amount_cents: refunding.amount_cents,
             provider: to_string(refunding.provider)
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, "forbidden: platform admin required to unforfeit deposit orders"}

        {:error, err} ->
          {:error, Cgc2046.Mcp.Errors.message(err, "failed to unforfeit order")}
      end
    end
  end

  # 域 argument 同款约束（1-500 字）在工具层前置：无效理由不建 pending
  # （第一段快速失败省一次确认往返）。
  defp validate_reason(reason) when is_binary(reason) do
    len = String.length(reason)

    if len >= 1 and len <= 500 do
      :ok
    else
      {:error, "reason must be 1-500 characters (got #{len})"}
    end
  end

  defp validate_reason(_), do: {:error, "reason is required (1-500 characters)"}

  # tenant 收紧订单归属：他租户 order_id 与不存在同一「not found」，不泄露存在性
  # （retry_refund 同款）。
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
