defmodule Cgc2046.Recruitment do
  @moduledoc """
  志愿者招募域（Hacker Start 1024 campaign；R8/R9/R13）。

  三个租户资源（KTD2：`workspace_id` + `global?(true)`，对齐 Enrollment /
  SpeakerInvitation 主流模式）：

  - `RecruitmentCohort`——招募批次（名称 / 申请截止 / 执行周期 / draft|open|closed，
    同一 workspace 至多一个 open）；
  - `ResumeProfile`——简历档案（一人一档，跨批复用、可更新；PIPL 边界）；
  - `VolunteerApplication`——志愿者申请（同批一份，段位状态机见 R12/U3）。

  权限矩阵见各资源 policy；管理面边界复用
  `Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin`，platform_admin 穿透。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  admin do
    # 安全门控由 :admin_browser pipeline 的 PlatformAdminPlug 承担（各 domain 同款）
    show?(true)
    name("Recruitment")
    resource_group_labels(recruitment: "招募")
  end

  graphql do
    authorize?(true)
  end

  resources do
    resource(Cgc2046.Recruitment.RecruitmentCohort)
    resource(Cgc2046.Recruitment.ResumeProfile)
    resource(Cgc2046.Recruitment.VolunteerApplication)
  end
end
