defmodule Cgc2046.Courses do
  @moduledoc """
  课程域（ADR-0009 PR②）：Course 聚合独立成 Courses 限界上下文
  （长内容形态与学习闭环迭代重心，与 Event 运营面分叉）。

  KTD1 域纪律：与 Cgc2046.Api / Cgc2046.Payments / Cgc2046.Admission 同款——
  `graphql do authorize?(true) end`，未带 policy 的动作默认拒绝，防止意外公开
  租户资源。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  admin do
    # 安全门控由 :admin_browser pipeline 的 PlatformAdminPlug 承担（同 Cgc2046.Api）
    show?(true)
    # #113 ops 面优化同款：domain 命名 + 资源分组标签（中文）
    name("Courses")
    resource_group_labels(courses: "课程")
  end

  graphql do
    authorize?(true)
  end

  resources do
    # ADR-0009 R3：Course 归 Courses context
    resource(Cgc2046.Courses.Course)
  end
end
