defmodule Cgc2046Web.GraphqlSchema.PaymentOperations do
  @moduledoc """
  高风险支付操作两段确认域（web 面 R15/R17/R18）GraphQL 面：mutation 字段、
  payload 类型，以及两个专用 helper（pending_confirmation_payload /
  mutation_error_payload）——仅本域使用，留在本文件。
  """

  use Absinthe.Schema.Notation

  import Cgc2046Web.GraphqlSchema.Helpers

  object :payment_operation_mutations do
    # ── 高风险支付操作两段确认（web 面 R15/R17/R18；编排在
    #    Cgc2046Web.PaymentConfirmation，复用 Mcp.PendingOperation/Confirmation，
    #    confirm 段分派到同名 MCP 工具的 execute_confirmed/2，domain 的
    #    CAS/审计/worker 路径不变）──

    @desc "管理员单笔退款（R15）：第一段——建 pending 并返回后端生成的确认摘要（不落业务库）；confirmOperation 确认后真正执行"
    field :refund_order, :pending_operation_confirmation do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          actor
          |> Cgc2046Web.PaymentConfirmation.request_refund(id)
          |> pending_confirmation_payload()
        end)
      end)
    end

    @desc "退款失败重试（R17）：第一段——refund_failed 单建 pending（不落业务库）；confirmOperation 确认后重入退款链"
    field :retry_refund, :pending_operation_confirmation do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          actor
          |> Cgc2046Web.PaymentConfirmation.request_retry_refund(id)
          |> pending_confirmation_payload()
        end)
      end)
    end

    @desc "免缴（R18）：第一段——payment_pending 报名建 pending（不落业务库）；confirmOperation 确认后跳过支付直接确认"
    field :waive_payment, :pending_operation_confirmation do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          actor
          |> Cgc2046Web.PaymentConfirmation.request_waive(id)
          |> pending_confirmation_payload()
        end)
      end)
    end

    @desc "确认并执行 pending 操作（仅本人、pending 且未过期；effect 失败 pending 回滚可重试）"
    field :confirm_operation, :operation_resolution do
      arg(:pending_id, non_null(:id))

      resolve(fn _, %{pending_id: pending_id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Mcp.Confirmation.confirm(actor, pending_id) do
            {:ok, %{pending_id: id, status: status}} ->
              {:ok, %{pending_id: id, status: status, errors: []}}

            {:error, message} ->
              {:ok,
               %{
                 pending_id: nil,
                 status: nil,
                 errors: [
                   mutation_error_payload(
                     message,
                     Cgc2046.Mcp.Confirmation.confirm_failed_code()
                   )
                 ]
               }}
          end
        end)
      end)
    end

    @desc "取消 pending 操作（仅本人、pending；取消后不执行，过期自动失效）"
    field :cancel_operation, :operation_resolution do
      arg(:pending_id, non_null(:id))

      resolve(fn _, %{pending_id: pending_id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Mcp.Confirmation.cancel(actor, pending_id) do
            {:ok, %{pending_id: id, status: status}} ->
              {:ok, %{pending_id: id, status: status, errors: []}}

            {:error, message} ->
              {:ok,
               %{
                 pending_id: nil,
                 status: nil,
                 errors: [
                   mutation_error_payload(
                     message,
                     Cgc2046.Mcp.Confirmation.cancel_failed_code()
                   )
                 ]
               }}
          end
        end)
      end)
    end
  end

  # ── 高风险支付操作两段确认（web 面；payload 式错误同 accept_invitation_result 先例）──

  object :pending_operation_confirmation do
    @desc "refundOrder/retryRefund/waivePayment 第一段返回：pendingId + 后端生成的确认摘要；errors 为业务错误（未建 pending）"
    field(:pending_id, :id)
    field(:summary, :string)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  object :operation_resolution do
    @desc "confirmOperation/cancelOperation 返回：status = confirmed | cancelled；errors 为业务错误"
    field(:pending_id, :id)
    field(:status, :string)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  # 两段确认第一段结果 → pending_operation_confirmation payload：业务错误进
  # payload errors（与自动 mutation 同通道，前端按 code 查文案），不抛顶层 error
  defp pending_confirmation_payload({:ok, %{pending_id: pending_id, summary: summary}}),
    do: {:ok, %{pending_id: pending_id, summary: summary, errors: []}}

  defp pending_confirmation_payload({:error, %{message: message, code: code}}),
    do: {:ok, %{pending_id: nil, summary: nil, errors: [mutation_error_payload(message, code)]}}

  # 手写 payload 的最小 mutation_error 形状（decide_speaker_invitation 同款先例）
  defp mutation_error_payload(message, code), do: %{message: message, code: code}
end
