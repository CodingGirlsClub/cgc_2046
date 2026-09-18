defmodule Cgc2046.Flashback do
  @moduledoc """
  闪念间（In a Flash）域（KTD1）：2012-2018 年 Rails Girls / Girls Coding Day
  历史报名档案的唤醒与重连——拍立得显影、校友墙（时间胶囊）、Action 卡与
  首程 token。

  历史档案是死数据，不混入现行 admission/events 域；Action 卡成场
  （scheduled）时才创建真实 Event 挂 1024 Initiative（U7）。域纪律同
  `Cgc2046.Admission`：`graphql do authorize?(true) end`，资源不定义 graphql
  查询/变更——GraphQL 面全部为 `Cgc2046Web.GraphqlSchema` 手写 field（免登录
  token 流，U2），未带 policy 的动作默认拒绝。

  ## 授权面（U1 起钉住）

  - 读/写 policy 仅放行 `Cgc2046.Accounts.Policies.PlatformAdmin`（运营观测）；
  - token 持有者的免登录读写走服务端 `authorize?: false` 路径（token 即凭据，
    读 policy 不适用——同 `Accounts.TokenCredential` 语义），入口全部收敛在
    U2 的手写 mutation（action 内复验 token）；
  - 管理动作（建卡/成场/批量生成/群发/导出）gate 于 PlatformAdmin。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  admin do
    # 安全门控由 :admin_browser pipeline 的 PlatformAdminPlug 承担（各 domain 同款）
    show?(true)
    name("Flashback")
    resource_group_labels(flashback: "闪念间")
  end

  graphql do
    authorize?(true)
  end

  resources do
    resource(Cgc2046.Flashback.EventArchive)
    resource(Cgc2046.Flashback.Person)
    resource(Cgc2046.Flashback.Token)
    resource(Cgc2046.Flashback.Answer)
    resource(Cgc2046.Flashback.Today)
    resource(Cgc2046.Flashback.QuoteLicense)
    resource(Cgc2046.Flashback.ActionCard)
    resource(Cgc2046.Flashback.Endorsement)
    resource(Cgc2046.Flashback.Touch)
    resource(Cgc2046.Flashback.Outreach)
    resource(Cgc2046.Flashback.Redemption)
  end
end
