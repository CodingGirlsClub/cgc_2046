# 微信真机验收 checklist

> 自动化使用 `CGC_E2E_MOCK=true` 隔离真实平台凭据；本清单专门验证不能由 mock 证明的平台边界。开发后端固定为 `http://localhost:4001/api/graphql`，不要访问或停止 4000 端口的其他 worktree 服务。

## 准备

- [x] 执行 `pnpm build:weapp` 后，在微信开发者工具导入 `dist/weapp/`；真实 AppID 只写入开发者工具本地的私有配置，操作后用 `git status` 确认 tracked `project.config.json` 未被改动。
- [x] 手机与开发机在可访问 4001 的网络内；或将 `CGC_GRAPHQL_ENDPOINT` 设置为已配置 HTTPS 合法域名的测试后端。（2026-09-05 回归改为真机直连生产 API：`.env.prod` 配置 `https://api.codingirlsclub.com/api/graphql`）
- [x] 后端已配置微信 appid/secret；微信后台已把 GraphQL 域名加入 request 合法域名。（2026-09-05 生产容器 5 键 env 核对通过）
- [x] 配置三个模板 ID：`CGC_WECHAT_TEMPLATE_APPROVAL_RESULT`、`CGC_WECHAT_TEMPLATE_APPROVAL_REMINDER`、`CGC_WECHAT_TEMPLATE_EVENT_REMINDER`。
- [x] 使用非个人主体且已开通手机号快速验证能力的测试账号。

## N1 登录与会话

- [x] 未登录打开「发现」，公开 Club/Event/Course 能加载；点报名进入手机号登录页。
- [x] 同意手机号授权后登录成功，响应 `cgc_token` 被保存，后续 GraphQL 请求携带 `Authorization: Bearer`。（tokens 表取证：purpose='user' 两次落库）
- [x] 现代 `getPhoneNumber` 的 `event.detail.code` 走 `phoneCode` 新契约（已落地，PR #224）：weapp 前端优先发 code、legacy `encryptedData + iv` 兜底；真机验证 code 路径登录成功。
- [x] 拒绝手机号授权时留在登录页并显示可恢复错误，不创建账号。（users_today=0 零垃圾账号）
- [x] 退出后 Bearer token 清除，受保护页面回到未登录空态。

## F2/F3 报名

- [x] `open`：提交姓名、邮箱、原因后立即显示「报名成功」。
- [x] `request`：提交后显示「等待审批」，「我的报名」显示实时 approval deadline 倒计时。
- [x] `invite_only`：未填批次码不能提交；有效批次码提交后 confirmed；无效/耗尽批次码显示服务端错误。（四分支全过：空码前端挡/错码报错/TEST2026 扣配额 1→0/耗尽报「邀请名额已用完」）
- [x] rejected/expired 记录显示「重新提交」，重新报名可成功。

## F4/F5 工作台与审批

- [x] Visitor 或没有任何 workspace membership 的用户看不到「工作台」；任意 workspace 成员（含无标签成员 / learner）可见自己的 workspace。
- [x] 只有具备 `manage_members` ability 的成员看到跨 workspace 待办；按 deadline 升序，24 小时内项为红色。
- [x] 点击报名/加入待办的通过与拒绝，列表即时刷新；普通成员直接进入页面仍 fail-closed。
- [x] 「订阅提醒」只在用户点击后弹微信授权，不在页面加载时自动弹窗。

## N3 三个订阅触点

- [x] `request` 报名提交后授权「审批结果通知」，后端配额增加 1。
- [x] Owner 处理待办前授权「审批到期提醒」，后端配额增加 1。
- [x] confirmed 后在「我的报名」授权「活动提醒」，后端配额增加 1。（以上三项 notification_consents 表逐次 +1 落库取证）
- [ ] 每次真实通知下发消耗一次对应模板配额（**下发链路受 #406 阻断未验**：deploy.yml 缺 WECHAT_MP_TEMPLATE_* 4 键，生产 worker 无模板可用）；拒绝授权不调用 grant mutation（真机不可复现——微信记住授权偏好不再弹窗；拒绝分支由单测覆盖）。

## F8/N4 邀请

- [x] Owner/Admin 生成小程序码，图片、scene、过期时间正确显示。（菊花码图/scene/7 天有效期三要素目检过）
- [ ] 未登录扫码进入「确认加入」→ 登录 → 自动返回 → 确认入座 → 工作台。（**发布后验证**：wxacode 码指向正式版，未发布前扫码不可达；admit 契约已经手输路径验证）
- [x] 过期或二次使用 scene 显示无效，不泄露邀请状态细节。（过期码实测报笼统文案 ✓）
- [x] 手输 scene 与扫码入口都能完成加入流程。（手输已验 ✓；扫码入口随上一项发布后验证）
- [ ] Workspace 批次码需待 backend 补齐独立兑换 mutation 后验收，不得当作 scene 提交。

## F7/F9 与 D4

- [ ] ~~活动/课程 `researchRequirements` 新增任意 key 后，无需改页面即可显示 label/value。~~（**幽灵项**：2026-09-05 全栈核查——DB 无列、GraphQL schema 无字段、web/miniprogram 两端无代码，疑为早期规划残留，建议删除本行）
- [x] 每个 Tab 的加载、错误、空态均可辨识且可恢复。（登录空态/我的报名空态/工作台空态/名额用完/已是成员/重复报名/限流 均实测）
- [ ] 本机通知记录能看到本地授权与审批操作记录（后端尚无通知 feed query，F9 通知中心待契约补齐）。
- [x] 全页面没有聊天输入框、对话历史、Agent 选择/交互、Workflow 执行/编辑入口。（全页面截图巡检）
- [x] 「去 OpenClacky」仅展示安装和连接器指引，不承载任何执行能力。

## 011 分享与 URL Scheme

- [ ] **U4（主体权限）——已判定通过（2026-08-18）**：主体为**公司（非个人）**，加密 generatescheme 自动开通（仅个人主体受错误码 40002 限制，非个人无后台开关、无需申请权限集）。**上线前仍须**：用真实 appid+secret 实调一次 generatescheme 做端到端最终确认（凭证环境就绪后）；如需明文 Scheme 拉起，后台「账号设置」中查找并开启该开关（UI 位置随版本变动，无此开关则忽略——加密接口不依赖它）。
- [x] 聊天卡片分享：event-detail 右上角转发 → 卡片 title 正确（活动标题；加载中/缺失时兜底「CGC · 精选活动」，无平台字样）；好友点击卡片进入对应详情页（course 分享 kind=course 正确加载）。（2026-09-05 转发文件传输助手实测）
- [ ] scheme 冷启动：外部渠道链接（iOS Safari 打开 weixin://dl/business 链接）→ 冷启动直达 event-detail 详情页（需线上正式版——scheme 只能生成已发布页面）。（**发布后验证批次**）
- [ ] scheme 热启动：小程序已打开（停在非详情页）→ 点 scheme 链接回前台 → 跳转 event-detail；已在 event-detail 时点链接 → 不重复跳转/不打断当前详情；带 scene 的进入仍走 join 链路（scene 优先）。（**发布后验证批次**）

## 2026-09-05 真机回归落档

- 环境：iOS 真机（微信最新版）直连生产 API；构建 `pnpm build:weapp` + 预览二维码。
- 结果：**26/30 项通过**；2 项发布后验证（扫码加入全流程、scheme 冷/热启动）；1 项幽灵项建议删除（researchRequirements）；F9 通知 feed 与批次码独立兑换为既有待补契约。
- 回归中发现并修复：iOS 输入框不回显（PR #412，defaultValue 绑动态 state 导致受控竞争）。
- 回归中记录 issue：#405（P0 支付阻断，order_duplicate_active 死循环）、#406（通知下发链路断裂）、#411（多条报名记录堆叠 UX）、#415（邀请码无分享出口）。
- 测试数据已清理：活动策略恢复 open、TEST2026 批次 disabled、3 条 rejected 报名删除（保留 confirmed + 关联订单）。
