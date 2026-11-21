defmodule Cgc2046.LlmGateway do
  @moduledoc """
  Managed LLM Gateway 域（Phase 1–3B）：个人算力钱包、工作台批量派发留痕、
  FIFO 到期批次、双成本用量账本，以及独立于报名支付的算力收银台订单。

  资源只暴露读面；钱包/批次写路径全部收敛在 `Cgc2046.LlmGateway.Ledger` 的
  原子 SQL（预授权 hold、结算扣费、批量派发），收银台写路径收敛在
  `Cgc2046.LlmGateway.PaymentOrders`，避免 Ash action 绕过行锁与不变量。
  """

  use Ash.Domain, otp_app: :cgc_2046

  resources do
    resource(Cgc2046.LlmGateway.Wallet)
    resource(Cgc2046.LlmGateway.WorkspaceGrantBatch)
    resource(Cgc2046.LlmGateway.WorkspacePoolEntry)
    resource(Cgc2046.LlmGateway.CreditGrant)
    resource(Cgc2046.LlmGateway.UsageLog)
    resource(Cgc2046.LlmGateway.PaymentOrder)
    resource(Cgc2046.LlmGateway.Provider)
    resource(Cgc2046.LlmGateway.ProviderApiKey)
    resource(Cgc2046.LlmGateway.ProviderModel)
  end
end
