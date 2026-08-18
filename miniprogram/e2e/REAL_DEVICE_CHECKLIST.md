# 微信真机验收 checklist

> 自动化使用 `CGC_E2E_MOCK=true` 隔离真实平台凭据；本清单专门验证不能由 mock 证明的平台边界。开发后端固定为 `http://localhost:4001/api/graphql`，不要访问或停止 4000 端口的其他 worktree 服务。

## 准备

- [ ] 执行 `pnpm build:weapp` 后，在微信开发者工具导入 `dist/weapp/`；真实 AppID 只写入开发者工具本地的私有配置，操作后用 `git status` 确认 tracked `project.config.json` 未被改动。
- [ ] 手机与开发机在可访问 4001 的网络内；或将 `CGC_GRAPHQL_ENDPOINT` 设置为已配置 HTTPS 合法域名的测试后端。
- [ ] 后端已配置微信 appid/secret；微信后台已把 GraphQL 域名加入 request 合法域名。
- [ ] 配置三个模板 ID：`CGC_WECHAT_TEMPLATE_APPROVAL_RESULT`、`CGC_WECHAT_TEMPLATE_APPROVAL_REMINDER`、`CGC_WECHAT_TEMPLATE_EVENT_REMINDER`。
- [ ] 使用非个人主体且已开通手机号快速验证能力的测试账号。

## N1 登录与会话

- [ ] 未登录打开「发现」，公开 Club/Event/Course 能加载；点报名进入手机号登录页。
- [ ] 同意手机号授权后登录成功，响应 `cgc_token` 被保存，后续 GraphQL 请求携带 `Authorization: Bearer`。
- [ ] 现代 `getPhoneNumber` 的 `event.detail.code` 需待 backend 补齐 `phoneCode` 契约；当前 schema 仅接受 legacy `encryptedData + iv`。
- [ ] 拒绝手机号授权时留在登录页并显示可恢复错误，不创建账号。
- [ ] 退出后 Bearer token 清除，受保护页面回到未登录空态。

## F2/F3 报名

- [ ] `open`：提交姓名、邮箱、原因后立即显示「报名成功」。
- [ ] `request`：提交后显示「等待审批」，「我的报名」显示实时 approval deadline 倒计时。
- [ ] `invite_only`：未填批次码不能提交；有效批次码提交后 confirmed；无效/耗尽批次码显示服务端错误。
- [ ] rejected/expired 记录显示「重新提交」，重新报名可成功。

## F4/F5 工作台与审批

- [ ] Visitor 或没有任何 workspace membership 的用户看不到「工作台」；任意 workspace 成员（含无标签成员 / learner）可见自己的 workspace。
- [ ] 只有具备 `manage_members` ability 的成员看到跨 workspace 待办；按 deadline 升序，24 小时内项为红色。
- [ ] 点击报名/加入待办的通过与拒绝，列表即时刷新；普通成员直接进入页面仍 fail-closed。
- [ ] 「订阅提醒」只在用户点击后弹微信授权，不在页面加载时自动弹窗。

## N3 三个订阅触点

- [ ] `request` 报名提交后授权「审批结果通知」，后端配额增加 1。
- [ ] Owner 处理待办前授权「审批到期提醒」，后端配额增加 1。
- [ ] confirmed 后在「我的报名」授权「活动提醒」，后端配额增加 1。
- [ ] 每次真实通知下发消耗一次对应模板配额；拒绝授权不调用 grant mutation。

## F8/N4 邀请

- [ ] Owner/Admin 生成小程序码，图片、scene、过期时间正确显示。
- [ ] 未登录扫码进入「确认加入」→ 登录 → 自动返回 → 确认入座 → 工作台。
- [ ] 过期或二次使用 scene 显示无效，不泄露邀请状态细节。
- [ ] 手输 scene 与扫码入口都能完成加入流程。
- [ ] Workspace 批次码需待 backend 补齐独立兑换 mutation 后验收，不得当作 scene 提交。

## F7/F9 与 D4

- [ ] 活动/课程 `researchRequirements` 新增任意 key 后，无需改页面即可显示 label/value。
- [ ] 每个 Tab 的加载、错误、空态均可辨识且可恢复。
- [ ] 本机通知记录能看到本地授权与审批操作记录（后端尚无通知 feed query，F9 通知中心待契约补齐）。
- [ ] 全页面没有聊天输入框、对话历史、Agent 选择/交互、Workflow 执行/编辑入口。
- [ ] 「去 OpenClacky」仅展示安装和连接器指引，不承载任何执行能力。

## 011 分享与 URL Scheme

- [ ] **U4（D 级阻断，上线前必查）**：官方后台确认本小程序主体的 URL Scheme 权限；用现有 appid 实调一次 generatescheme 验证可生成（若判无权限，scheme 全链路不可用）。
- [ ] 聊天卡片分享：event-detail 右上角转发 → 卡片 title 正确（活动标题；加载中/缺失时兜底「CGC · 精选活动」，无平台字样）；好友点击卡片进入对应详情页（course 分享 kind=course 正确加载）。
- [ ] scheme 冷启动：外部渠道链接（iOS Safari 打开 weixin://dl/business 链接）→ 冷启动直达 event-detail 详情页（需线上正式版——scheme 只能生成已发布页面）。
- [ ] scheme 热启动：小程序已打开（停在非详情页）→ 点 scheme 链接回前台 → 跳转 event-detail；已在 event-detail 时点链接 → 不重复跳转/不打断当前详情；带 scene 的进入仍走 join 链路（scene 优先）。
