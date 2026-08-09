# 抖音/小红书裁剪端真机验收 checklist

> Phase 4 裁剪端（2 Tab 漏斗：发现/我的报名）。平台能力（tt.login/xhs.login、手机号授权、订阅消息）无真实凭据，自动化只能验证编译与 mock；本清单验证不能由构建证明的平台边界。开发后端固定 `http://localhost:4001/api/graphql`。

## 准备

- [ ] 抖音开放平台 / 小红书专业号：非个人主体资质 + 小程序 appid/secret（§9 human 决策项：主体资质 + ICP）
- [ ] 抖音：执行 `pnpm build:tt` 后，开发者工具导入 `dist/tt/`（Taro 输入模板为 `project.tt.json`，构建输出为 `dist/tt/project.config.json`）；真实 AppID 只在工具本地设置。
- [ ] 小红书：执行 `pnpm build:xhs` 后，开发者工具导入 `dist/xhs/`；不要使用微信 `project.config.json`。
- [ ] 手机与开发机可访问 4001（或将 `CGC_GRAPHQL_ENDPOINT` 设为已配置合法域名的测试后端）
- [ ] 后端已配置抖音/小红书 appid/secret；平台后台把 GraphQL 域名加入 request 合法域名
- [ ] 抖音订阅消息模板 ID 配 `CGC_TT_TEMPLATE_APPROVAL_RESULT` / `CGC_TT_TEMPLATE_EVENT_REMINDER`；小红书走服务通知，无需模板 ID

## 裁剪 IA（构建证据：dist/tt、dist/xhs 的 app.json）

- [ ] 仅注册 7 页：发现/我的报名/活动详情/登录/报名表单/报名结果/加入；tabBar 仅「发现/我的报名」
- [ ] 无 工作台/我的/OpenClacky 页（管理/协作功能不做，§2 裁剪原则）
- [ ] 微信端（weapp）仍是 4 Tab + 全部页面，无回归

## N1 登录

- [ ] `tt.login` / `xhs.login` 拿到 code，后端 `signInWithPlatform` 三平台 code2session 成功建号/挂 Identity
- [ ] 平台手机号授权返回 **`code`（新契约）而非 encryptedData/iv 时**：当前 schema 仅接受 legacy `encryptedData+iv`，需待 backend 补齐 phoneCode 契约——真机若报「手机号授权数据不完整」，记录响应结构交 backend 侧
- [ ] 拒绝手机号授权时留在登录页显示可恢复错误，不创建账号
- [ ] 登录按钮文案显示「抖音手机号快捷登录」/「小红书手机号快捷登录」（非「微信」）

## F2/F3 报名

- [ ] `open`：提交立即 confirmed；`request`：提交 pending + 「我的报名」倒计时；`invite_only`：批次码必填/服务端校验
- [ ] rejected/expired 显示「重新提交」，重报名成功

## N3 订阅（裁剪端仅学习者两场景：审批结果 / 活动提醒）

- [ ] request 报名提交后订阅「审批结果通知」：抖音弹 `requestSubscribeMessage` 授权，后端 quota +1
- [ ] confirmed 后在「我的报名」订阅「活动提醒」
- [ ] 小红书：无前端授权弹窗（服务通知由平台后台规则下发），确认 grant 配额照常上报、不 crash
- [ ] 未配置模板 ID 时按钮给出可读错误（「缺少抖音订阅消息模板 ID…」），不白屏不崩溃
- [ ] 「我的报名」底部提示「审批结果将通过本端订阅消息通知你」（本端提示，非跨端引导）

## F8/N2 邀请加入

- [ ] 扫小程序码/手输 scene 确认加入；裁剪端入座后回落到「我的报名」（无工作台 Tab）
- [ ] 过期/二次使用 scene 显示无效，不泄露邀请状态

## 零导流自检（合规红线，§2）

- [ ] 裁剪端产物 grep 无「微信/OpenClacky/二维码/口令」跨端引导（orchestrator 已 grep dist/tt、dist/xhs 无命中）
- [ ] 人工抽查：登录/报名/结果页无任何「去微信」「加微信」「扫码添加」字样或机制
- [ ] 深度功能认知由官网/公众号承担，裁剪端内零跨端引导

## D4 边界

- [ ] 裁剪端无聊天输入框、对话历史、Agent 选择/交互、Workflow 执行/编辑入口（与微信端一致）
- [ ] F7 详情 `researchRequirements` 新增 key 无需改页面即可显示

## 已知缺口（待 backend/平台契约，非本端可解）

- [ ] 抖音/小红书手机号 `code` 契约（真机验证响应结构后交 backend）
- [ ] 小红书服务通知的授权交互与下发语义（平台文档 + 真机确认后回写）
- [ ] 抖音/小红书模板 ID 申请与运维归属（§9 Q3 human 项）
