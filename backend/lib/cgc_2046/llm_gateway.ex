defmodule Cgc2046.LlmGateway do
  @moduledoc """
  Managed LLM Gateway 域（Phase 1）：个人算力钱包、工作台批量派发留痕、
  FIFO 到期批次与双成本用量账本。

  资源只暴露读面；写路径全部收敛在 `Cgc2046.LlmGateway.Ledger` 的原子 SQL
  （预授权 hold、结算扣费、批量派发），避免 Ash action 绕过行锁与不变量。
  """

  use Ash.Domain, otp_app: :cgc_2046

  resources do
    resource(Cgc2046.LlmGateway.Wallet)
    resource(Cgc2046.LlmGateway.WorkspaceGrantBatch)
    resource(Cgc2046.LlmGateway.CreditGrant)
    resource(Cgc2046.LlmGateway.UsageLog)
  end
end
