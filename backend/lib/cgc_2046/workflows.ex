defmodule Cgc2046.Workflows do
  @moduledoc """
  工作流域（ADR-0009 PR⑤ U8，旧 Api domain 退役归位）：确定性编排引擎家族——
  WorkflowDefinition（蓝图）/ Step / StepRole / WorkflowRun（执行实例）/
  SignalLog（入向信号日志）/ SignalIdempotency（信号幂等）。generic 引擎
  context：依赖方向恒为 workflow → 业务 Action 接口（定稿 §5.4）。

  KTD1 域纪律：与 Cgc2046.Payments / Cgc2046.Admission 同款——
  `graphql do authorize?(true) end`，未带 policy 的动作默认拒绝，防止意外公开
  租户资源。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  admin do
    # 安全门控由 :admin_browser pipeline 的 PlatformAdminPlug 承担（各 domain 同款）
    show?(true)
    # #113 ops 面优化同款：domain 命名 + 资源分组标签（中文）
    name("Workflows")
    resource_group_labels(workflows: "工作流")
  end

  graphql do
    authorize?(true)
  end

  resources do
    # Slice C workflow 引擎（#34-#39，ADR-0002 Jido + ADR-0003 pi 重构）
    resource(Cgc2046.Workflows.WorkflowDefinition)
    resource(Cgc2046.Workflows.Step)
    resource(Cgc2046.Workflows.StepRole)
    resource(Cgc2046.Workflows.WorkflowRun)
    resource(Cgc2046.Workflows.SignalLog)
    resource(Cgc2046.Workflows.SignalIdempotency)
  end
end
