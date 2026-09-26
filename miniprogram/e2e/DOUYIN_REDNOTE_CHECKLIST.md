# 抖音/小红书裁剪端真机验收 checklist

> 抖音端：2 Tab 漏斗（发现/我的报名）。小红书端（P0，2026-09-25 止血版）：2 Tab（发现/我的），
> 无订阅消息、无端内支付、闪念间为薄壳页。平台能力（tt.login/xhs.login、手机号授权）无自动化
> 桩，真机清单验证不能由构建证明的平台边界。开发后端固定 `http://localhost:4001/api/graphql`。

## 准备

- [ ] 抖音开放平台 / 小红书专业号：非个人主体资质 + 小程序 appid/secret（§9 human 决策项：主体资质 + ICP）
- [ ] 抖音：执行 `pnpm build:tt` 后，开发者工具导入 `dist/tt/`（Taro 输入模板为 `project.tt.json`，构建输出为 `dist/tt/project.config.json`）；真实 AppID 只在工具本地设置。
- [ ] 小红书：执行 `pnpm build:xhs` 后，小红书开发者工具导入 `dist/xhs/`；不要使用微信 `project.config.json`。
- [ ] 手机与开发机可访问 4001（或将 `CGC_GRAPHQL_ENDPOINT` 设为已配置合法域名的测试后端）
- [ ] 后端已配置抖音/小红书 appid/secret（`XHS_MP_APPID`/`XHS_MP_SECRET`）；平台后台把 GraphQL 域名加入 request 合法域名
- [ ] 抖音订阅消息模板 ID 配 `CGC_DOUYIN_TEMPLATE_APPROVAL_RESULT` / `CGC_DOUYIN_TEMPLATE_EVENT_REMINDER`；**小红书没有订阅消息能力**（平台无该 API，曾误传的「服务通知由平台后台下发」经核证不存在）——前端触点已整体下线（P0-2），`XHS_MP_TEMPLATE_*` 占位键将在 P1-1 随整条 xhs 通知链路一并删除，无需配置

## 裁剪 IA（构建证据：dist/tt、dist/xhs 的 app.json）

- [ ] 抖音端仅注册 9 页：发现/我的报名/倡导详情/活动详情/登录/报名表单/报名结果/加入/闪念间薄壳；tabBar 仅「发现/我的报名」
- [ ] 小红书端注册 11 页：上述 + **「我的」精简页（profile-lite）+ 隐私页（privacy）**；tabBar「发现/我的」（D2a，我的报名已降级为普通页，入口收进「我的」）
- [ ] 两裁剪端均无 工作台/OpenClacky/campaign/志愿者/核销/支付页（管理/协作/缴费功能不做）及闪念间深度页（长廊/写愿望等）
- [ ] 微信端（weapp）仍是全量 Tab + 全部页面，无回归

## N1 登录

- [ ] `tt.login` / `xhs.login` 拿到 code，后端 `signInWithPlatform` 三平台 code2session 成功建号/挂 Identity
- [ ] 手机号授权：**抖音走 phoneCode 契约**（`phone_code` 直传，`data.phone_number` 为明文）；**小红书走 legacy `encryptedData/iv` 解密路径**（详情见 Q1——P0-1 已按官方 Java 示例修正解密算法，真机复核解密成功率）
- [ ] 拒绝手机号授权时留在登录页显示可恢复错误，不创建账号
- [ ] 登录页《隐私授权说明》：小红书端**可点开**（P0-5 起注册隐私页，D7 候选正文）；抖音端保持纯文本
- [ ] 登录成功后，微信/小红书落「我的」Tab（小红书为精简页），抖音落「我的报名」Tab

## F2/F3 报名

- [ ] `open`：提交立即 confirmed；`request`：提交 pending + 「我的报名」倒计时；`invite_only`：批次码必填/服务端校验
- [ ] rejected/expired 显示「重新提交」，重报名成功
- [ ] **小红书缴费门（D1a）**：收费/押金场详情可看，报名按钮位置显示「本端暂未开放缴费报名」（register-form 深链同款阻断）；免费场报名正常；**任何页面不出现「网页端完成支付」字样**

## N3 订阅

- [ ] 抖音：request 报名提交后订阅「审批结果通知」，弹 `requestSubscribeMessage` 授权，后端 quota +1；confirmed 后「我的报名」订阅「活动提醒」
- [ ] 抖音：未配置模板 ID 时按钮给出可读错误（「缺少抖音订阅消息模板 ID…」），不白屏不崩溃
- [ ] **小红书：所有页面**不出现任何订阅按钮/触点（P0-2 下线）；不接受 grant 上报（rest 层零调用）
- [ ] 「我的报名」底部提示：抖音 = 「审批结果将通过本端订阅消息通知你」；小红书 = 「审批结果会更新在本页，可以随时回来查看」（无订阅消息可承诺）

## F8/N2 邀请加入

- [ ] 手输 scene 确认加入；入座后：微信/小红书落「我的」Tab，抖音落「我的报名」Tab
- [ ] **小红书扫码进入（scene 传参方式平台未文档化，Q5）**：P0 先只做手输，扫码加入待真机验证后再补
- [ ] 过期/二次使用 scene 显示无效，不泄露邀请状态

## N4 闪念间薄壳页（裁剪端）

- [ ] 从「我的」（小红书）/成场通知深链进入 `pages/flashback/index`，卡面渲染正常
- [ ] 分享面板：微信/抖音 = 转发/朋友圈/保存卡片三入口；**小红书 = 仅「转发」**（P0-6：无朋友圈概念、无 Canvas 2D）
- [ ] 未绑定档案的引导文案：小红书不提「网页端找回」（P0-3 零导流）

## 零导流自检（合规红线）

- [ ] 裁剪端产物 grep 无「微信/OpenClacky/二维码/口令」跨端引导（CI `node scripts/check-no-diversion.mjs` 构建后即跑，dist/tt、dist/xhs）
- [ ] `node scripts/check-no-diversion.mjs` 通过（禁用词含「网页端」，先解码 `\uXXXX` 再扫；纯文本 grep 看不见转义字符串，不可作验收依据）
- [ ] 人工抽查：登录/报名/结果页无任何「去微信」「加微信」「扫码添加」字样或机制
- [ ] 深度功能认知由官网/公众号承担，裁剪端内零跨端引导

## D4 边界

- [ ] 裁剪端无聊天输入框、对话历史、Agent 选择/交互、Workflow 执行/编辑入口（与微信端一致）
- [ ] F7 详情 `researchRequirements` 新增 key 无需改页面即可显示

## 已知缺口与待定项（真机/人工裁决）

- [ ] **Q1（尾部残余，真机复核）**：小红书官方《开放数据校验与解密》写「AES-128-CBC」却注「AESKey 24 字节」。P0-1 已定案按官方 Java 示例实现：cipher 取密钥实际长度（16/24/32 → AES-128/192/256）、填充自行去除并允许 1–32。真机首登解密成功率必须实测；若仍失败，以 Java 示例逐行比对修后端（测试 fixture 已是 24 字节密钥官方形状）
- [ ] **Q4（真机观察）**：Taro `@tarojs/plugin-platform-xhs` 1.2.2 的 `getPhoneNumber` 回调透传行为（登录按钮回调不触发时先查插件事件透传，不怀疑业务代码）
- [ ] **Q5（真机裁决）**：小红书扫码进入时 scene 如何传到页面，官方文档未写——P0 只做手输邀请码（见 F8/N2）
- [ ] ~~Q5-token~~（已定案）：小红书 access_token 换取系 POST `/api/rmp/token` + JSON 体 `{appid, secret}`（DC010382 已核对原文），7200s、最多两个同时有效；后端已按官方形状修正并加进程级缓存
- [ ] D7（人工，法务）：隐私政策小红书版正文定稿——`src/domain/privacy-content-xhs.ts` 为候选文本，法务确认后即定稿
- [ ] D8（人工，部分已到位）：ICP 备案号 = 京ICP备16008426号-7X（2026-09-22 通过），已渲染在「我的」页脚；**剩余**：本次过审版本号——到位后 CHANGELOG 按 ADR-0016 立 `[小红书 vX.Y.Z]` 节点
