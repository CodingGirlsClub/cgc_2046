defmodule Cgc2046.Mcp.Tools.GetOrderStatus do
  @moduledoc """
  本人报名的订单安全摘要（role-agent-journeys-v2 S7，R34/AE7；`membership:
  :deferred`，workspace_id + enrollment_id 必填）。

  取该报名**最新一笔订单**（非终态优先——每报名至多一笔非终态，非终态恒为
  最新）；无订单 → `order: nil`。`checkout_url` 仅 pending 订单给出
  （继续/完成支付入口）。

  **渠道凭据红线（§B#19）**：DTO 白名单仅 `id / amount_cents / provider /
  status / expires_at / paid_at`——prepay 参数、nonce、签名、out_trade_no、
  transaction_id、渠道回调原文**永不出本面**（凭据形状只在 Payments 域内部
  metadata，本工具不触碰 metadata 列；「渠道凭据不落 Order 列」的域红线在
  工具层再收一道）。

  归属：他人报名 → forbidden（审计落 :forbidden）；他工作台报名与不存在
  返回同一 not found（不泄存在性）。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Mcp.Tools.LearnerJourney
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Payments.Order

  require Ash.Query

  # 非终态（部分唯一索引 unique_active_order 同款口径）：pending/paid/refunding/
  # refund_failed；terminal = refunded/cancelled/expired。
  @non_terminal_statuses [:pending, :paid, :refunding, :refund_failed]

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID，须与报名所属工作台一致）")
    field(:enrollment_id, {:required, :string}, description: "报名 ID（UUID，须为本人报名）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_order_status", fn actor, workspace_id, params ->
        enrollment_id = params["enrollment_id"] || params[:enrollment_id]

        with {:ok, enrollment} <- fetch_enrollment(workspace_id, enrollment_id),
             :ok <- enrollee_only(enrollment, actor),
             {:ok, order} <- latest_order(enrollment, actor) do
          {:ok,
           %{
             order: order && order_dto(order),
             checkout_url: checkout_url(order, enrollment.id),
             enrollment_status: to_string(enrollment.status)
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 报名存在性 + 工作台作用域收紧（他工作台报名与不存在同一拒绝，不泄存在性）；
  # 归属判定在工具层（enrollee_only），读取 authorize?: false
  # （get_course_content fetch_course 同款纪律）。
  defp fetch_enrollment(workspace_id, enrollment_id) do
    case Ash.get(Enrollment, enrollment_id, authorize?: false) do
      {:ok, %Enrollment{workspace_id: ^workspace_id} = enrollment} ->
        {:ok, enrollment}

      {:ok, _} ->
        {:error, "enrollment not found: #{enrollment_id}"}

      {:error, _} ->
        {:error, "failed to load enrollment"}
    end
  end

  # 报名人本人（payments 域 enrollee_only 同款判定；他人报名 → forbidden，
  # 审计落 :forbidden）
  defp enrollee_only(%{user_id: user_id}, %{id: actor_id}) when user_id == actor_id, do: :ok

  defp enrollee_only(_enrollment, _actor),
    do: {:error, "forbidden: enrollment does not belong to the current actor"}

  # 最新订单：非终态优先（每报名至多一笔非终态 → 非终态恒为最新）；
  # 无订单 → nil。带 actor 走 policy（本人订单可读）。
  defp latest_order(enrollment, actor) do
    Order
    |> Ash.Query.filter(enrollment_id == ^enrollment.id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(50)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, orders} ->
        {:ok, Enum.find(orders, &(&1.status in @non_terminal_statuses)) || List.first(orders)}

      {:error, _} ->
        {:error, "failed to load order"}
    end
  end

  # 白名单投影：金额/渠道/状态/时间摘要；渠道凭据/单号/回调原文永不出本面（红线）
  defp order_dto(order) do
    %{
      id: order.id,
      amount_cents: order.amount_cents,
      provider: to_string(order.provider),
      status: to_string(order.status),
      expires_at: order.expire_at,
      paid_at: paid_at(order)
    }
  end

  # paid_at 无独立列：status=paid 时 updated_at 即 mark_paid 迁移时刻
  # （paid 后任何后续迁移都离开 paid 态，不会误读）
  defp paid_at(%{status: :paid, updated_at: updated_at}), do: updated_at
  defp paid_at(_order), do: nil

  # 支付入口：仅 pending 订单给下单页链接（继续/完成支付）
  defp checkout_url(%{status: :pending}, enrollment_id),
    do: LearnerJourney.checkout_url(enrollment_id)

  defp checkout_url(_order, _enrollment_id), do: nil
end
