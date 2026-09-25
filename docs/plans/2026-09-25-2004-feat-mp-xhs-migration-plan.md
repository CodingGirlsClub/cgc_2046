---
title: "feat: 小红书端功能迁移规划（微信全量端 → 小红书）"
date: 2026-09-25
type: feat
topic: mp-xhs-migration
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: "2026-09-25 会话：小红书小程序过审后，盘点微信端有而小红书端没有的功能并规划迁移"
execution: code
---

# feat: 小红书端功能迁移规划（微信全量端 → 小红书）

## 计划状态

这是一份交给 Owner 审批的规划，**不授权实施**。P0 可以先拆 issue 开工；P1 以后的切片要等「六、待决策」里的 D1–D8 定下来再拆。文中凡是没有在真机或生产环境跑过、只是从代码推断出来的结论，都标注为「推断」。

## 前提假设

1. 本次只规划小红书端（`TARO_ENV=xhs`）。抖音端（tt）不在范围内，但 X-1 会让 tt 和 xhs 不再共用同一份「裁剪端」配置。
2. 组织者（主理人、工作台管理员）继续使用微信端和 web；小红书端只服务学习者和校友。
3. 平台能力以 2026-09-25 的官方文档快照为准（见附录）。开放平台后台需要登录，本次没有进入，只能在后台确认的内容标注为 UNVERIFIED。

## 一、结论

小红书端的现状可以概括为四句话：**能浏览，大概率报不了名，收不到通知，付不了款**。

- **能浏览**：发现页、详情页支持游客浏览。
- **大概率报不了名（推断，需真机核验）**：
  - 后端取 token 用的是 `GET` 加 `app_id / app_secret / grant_type`（`backend/lib/cgc_2046/integrations/wechat/client.ex:481-514`），而官方文档是 `POST`，请求体为 `{appid, secret}`（已独立核对文档原文）。
  - 手机号解密硬性要求密钥为 16 字节（`client.ex:836`），官方 Java 示例是按密钥实际长度解密，并自行去除填充。
  - 登录必须拿到手机号，所以只要其中一环失败，就无法建号。
- **收不到通知**：
  - 小红书官方**没有**订阅消息或服务通知能力。后端默认的发送路径 `/api/rmp/subscribe/send`（`backend/config/runtime.exs:162`）实测返回 404。
  - 生产环境 xhs 模板 0/27（`.github/workflows/deploy.yml` 里没有任何 `XHS_MP_TEMPLATE_*`）。
  - 前端对 xhs 走 passthrough，直接上报 grant（`miniprogram/src/domain/subscription.ts:464-469`），但后端在模板缺配时会拒绝（`backend/lib/cgc_2046/notifications/consent.ex:87-95`）。结果是「我的报名 / 报名结果」页上的订阅按钮点了就报错（推断）。
- **付不了款**：
  - 小红书只支持担保交易（`xhs.requestGuaranteeOrderPayment`），开通需要企业专业号认证和类目开白。
  - 现在的文案「请在网页端完成支付」（`miniprogram/src/domain/payment.ts:480`、`miniprogram/src/pages/my-enrollments/index.tsx:208`）触碰了平台「引导用户去小红书客户端以外的地方操作」的规则，过审后仍可能在巡检时被判违规。

原来的「裁剪三原则」（定稿设计《小程序多端平台矩阵》，见 git `9858195b`）逐条重新评估如下：

| 原则 | 结论 |
|---|---|
| ① 裁剪端不做管理 / 协作 | **保留**。组织者面留在微信端和 web。 |
| ② 零跨端导流 | **保留并扩展**。小红书的规则比我们的禁用词表宽：「去网页端完成」也算导流。 |
| ③ JSAPI 支付仅微信端 | **改为**：各端走本平台原生支付；资质到位之前，小红书端内不出现任何付费入口。 |

后端几乎不按平台做门禁，访问控制全按角色走。因此闪念间、campaign 这类功能迁到小红书，主要是前端工作。真正需要后端投入的只有四块：支付、触达、内容安全、分享链接。

## 二、差距清单（微信端有、小红书端没有）

### 2.1 页面级

小红书端目前注册了 9 页（`miniprogram/src/app.config.ts:7-20`）。下面 17 页只在微信端注册。

| 域 | 微信端页面 | 小红书平台约束 | 迁移结论 |
|---|---|---|---|
| 账号与合规 | `profile`（退出登录、本机通知记录、加入工作台、备案号） | 有账号体系就必须能退出 | P0，做成「我的」精简版 |
| 账号与合规 | `privacy`（隐私政策） | 开发者协议 4.3 要求有隐私政策；现有正文含「微信」，过不了禁用词扫描 | P0，出小红书版正文（D7） |
| 交易 | `order-pay`（定价 / 押金支付 + 押金同意门） | 只能用担保交易；需要资质和类目；平台没有押金能力 | P3，依赖资质（D3） |
| 组织者 | `workspace`（审批）、`check-in`（扫码核销） | `xhs.scanCode` 可用 | 不迁（原则①） |
| 运营 | `campaign`（Hacker Start 1024） | 外部出口（剪贴板复制品牌邮箱，`miniprogram/src/domain/campaign.ts:62`）属于导流 | P1，视 D6 决定 |
| 运营 | `volunteer-apply`（招募 + 简历上传） | 没有 `chooseMessageFile`；表单留资可能被判「过度营销」（规范 6.13.1） | 不迁（web 已有 `apply/volunteer`） |
| 闪念间 | `flashback-journey / -corridor / -event / -today` | 页面文案含「微信」；Canvas 2D 不可用 | P2 本人面 |
| 闪念间 | `flashback-shared-card / -voices / -wishes` | 平台没有社区 / 社交类目，公开 UGC 属高风险（6.5.3） | P2 公开面，等平台确认（D4） |
| 闪念间 | `flashback-wish-write / -my-wishes` | 平台没有内容安全 API | P2 写面，先补审核 |
| 不迁 | `openclacky` | 导流红线 | 永不迁 |

### 2.2 共享页面内被屏蔽的功能

| 页面 | 微信端 | 小红书端现状 |
|---|---|---|
| `discover` | campaign 入口卡 | 隐藏（`index.tsx:124`） |
| `event-detail` | 扫码核销入口、主理人订阅 | 隐藏（`index.tsx:235`），符合原则① |
| `my-enrollments` | 去支付 | 显示「请在网页端完成支付」→ P0 下线这句 |
| `my-enrollments` / `enrollment-result` / `register-form` | 订阅消息触点 | 点击报错，或静默 grant 失败 → P0 下线 |
| `my-enrollments` | 参与者核销二维码（`CheckInQr`，Canvas 2D） | 渲染失败后退回显示 6 位码，可接受（推断） |
| `login` | 可点开的《隐私授权说明》 | 纯文本，点不开 → P0 |
| `flashback`（小红书专属薄壳页） | — | 端内**没有任何入口**，只能靠深链进入；分享面板里的「朋友圈」是微信概念；「保存卡片」依赖 Canvas 2D，在小红书端静默失败（推断） |
| 深链入口 `resolveAppShowRoute` | 分发到闪念间各页 | 带 `shareId / quoteId / wishId / token` 的链接会被导向小红书端**没注册**的页面，`navigateTo` 失败（`miniprogram/src/domain/share-route.ts`）；另外 `applyEntry` 固定按微信的 Tab 集合判断（`miniprogram/src/domain/entry.ts:41`） |

### 2.3 已上线的集成缺陷（迁移前必须先修）

| # | 位置 | 问题 | 依据 |
|---|---|---|---|
| I1 | `client.ex:481-514` | 取 token 的写法与官方文档不符，而且不缓存。官方规则是「新 token 生成后，旧 token 缩短为 5 分钟，同一时间最多两个有效」，并发登录时可能互相顶掉 | 官方文档原文（已核对） |
| I2 | `client.ex:836-849` | 解密只接受 16 字节密钥，并用标准 PKCS7 去填充；官方示例按密钥长度解密，允许 1–32 的填充 | 官方 Java 示例（调研） |
| I3 | `client.ex:327-343` | 小程序码请求把 token 放在 header、请求体缺 `width`，并且按 JSON base64 解析返回；官方要求 query 带 `appid / access_token`，返回的是 `image/png` | 调研实测 HTTP 400 |
| I4 | `runtime.exs:162` 及 xhs 模板注册表 | 调用的接口不存在；后端也没有 `render(:xhs, …)` 的字段渲染 | 调研实测 404 |
| I5 | `backend/lib/cgc_2046/flashback/wishes.ex:375-416`、`wish_writing.ex:56` | 内容审核只认微信身份：没有微信身份的用户**不做机审**，而且会被自动挂树公开。web 端单平台用户也有这个问题，属于既有缺口 | 代码 |
| I6 | `miniprogram/e2e/DOUYIN_REDNOTE_CHECKLIST.md` | 清单里的「13 键」「返回 phone_code_unsupported」「小红书走服务通知」均已过时或不成立；「平台后台把 GraphQL 域名加入 request 合法域名」对小红书不适用，官方写明服务器域名「不做限制」 | 与代码、文档对照 |

## 三、小红书平台特性与适配原则

1. **支付**：只能用担保交易，而且资质先行。通用类目已停止自助添加，要找小红书对接人开白；民办非企业单位和事业单位主体不能开通交易；小程序没有虚拟支付，线上课程不上小红书支付。
2. **触达**：平台没有订阅消息，触达改走三条路：登录时已拿到的手机号发短信（后端已有 SendCloud 短信集成 `backend/lib/cgc_2046/integrations/send_cloud/sms.ex`）、群聊组件、端内状态页。客服消息有 48 小时窗口，还需要先开通交易能力，暂不考虑。
3. **UGC**：平台没有审核 API，也没有社区类目。默认做法是「本人可见，人工精选后再公开」；用户想公开表达，引导他们用 `post-note-button` 发小红书笔记。这正好替代微信的朋友圈。
4. **分享**：
   - 站内分享是私信和群聊卡片；平台自带「分享到微信」（在微信里显示为 H5），插件默认已开启，我们不需要自己做文案。
   - `onShareAppMessage` 的分享图只支持网络图片；`post-note-button` 需要 https 图片。
   - 所以卡片图应该改为**服务端出图**。
5. **导流**：以「用户在小红书内完成」为判据，禁用词表只是底线。不能出现去网页端的引导、剪贴板外链、邮箱或电话出口；拨号必须用 `xhs.makePhoneCall`。
6. **渲染**：
   - 没有 Canvas 2D（节点 API 不支持），不支持自定义 tabBar。我们的自绘 TabBar 在隐藏原生 tabBar 后已经过审，可以继续用。
   - Taro 小红书插件停在 1.2.2（2024-12），之后没有更新。新能力通过原生 `xhs.*` 调用，用 `canIUse` 做兜底。
7. **审核**：首屏有效内容要在 3 秒内；必须能退出登录；必须有隐私政策；每次发版审核 3–5 个工作日。

## 四、迁移分期

### P0 · 止血与合规（不依赖外部资质，建议本周完成）

后端部署和小红书发版可以分开进行：P0-1 只涉及服务端，可以先上。

| 切片 | 内容 | 端 | 验收 |
|---|---|---|---|
| P0-1 登录链路 | ① 人工真机冒烟（5 分钟）：在小红书 App 里打开小程序完成一次登录，确认现状；② 不管冒烟结果如何，都按官方文档修正 I1、I2、I3：token 改为 POST 并缓存（多节点部署要共享缓存或单点刷新），解密按官方示例，小程序码请求按官方形状；③ 把 `backend/test/support/miniprogram_fixtures.ex` 里基于假设写的 xhs fixture 改成官方形状，否则测试会一直绿、生产却一直坏 | 后端 | 真机登录成功，并附后端测试输出 |
| P0-2 订阅触点下线 | `subscriptionTransport` 对 xhs 返回「不支持」，页面不再渲染订阅按钮，`register-form` 不再发起无效的 grant；把「审批结果将通过本端订阅消息通知你」（`my-enrollments/index.tsx:285`）改成真实的说法 | 前端 | `node --test` 钉住 transport 判据；真机上无订阅按钮 |
| P0-3 去掉站外支付引导 | 按 D1 处理收费和押金场次，删除「请在网页端完成支付」 | 前端 | `dist/xhs` 中 grep 不到「网页端」 |
| P0-4 深链按平台过滤 | 路由目标必须是本端已注册的页面，否则退回（闪念间类 → `pages/flashback/index`，其余 → 发现页）；`applyEntry` 按当前平台的 Tab 集合判断 | 前端 | `tests/share-route.test.ts` 补 xhs 用例 |
| P0-5 「我的」精简页 | 用户信息、退出登录、我的报名入口、隐私政策（小红书版，D7）、小红书小程序备案号（D8）、手输邀请码加入、闪念间入口；Tab 结构见 D2 | 前端 | 真机上可以退出并重新登录；禁用词扫描通过 |
| P0-6 薄壳页分享面板 | 小红书端隐藏「朋友圈」和「保存卡片」，只保留「转发」；P2-4 上线后再恢复 | 前端 | 真机 |
| P0-7 账本与文档 | `CHANGELOG.md` 按 ADR-0016 新增 `[小红书 vX.Y.Z]` 节点（D8）；README 补小红书发版流程；更正 I6 | 文档 | — |

### P1 · 触达与活动漏斗

| 切片 | 内容 | 依赖 |
|---|---|---|
| P1-1 触达通道替换 | 只有小红书身份的用户，学习者类通知（审批结果、活动提醒、改期、报名成功、核销码）改发 SendCloud 短信。按用户去重：已有微信订阅额度的走微信，没有的才发短信。同一切片内**删除** xhs 小程序通知的整条链路：`request_notification(:xhs)`、`runtime.exs` 里 27 个 xhs 模板键和发送路径、`config.exs` 和 `.env.example` 里的占位、前端 passthrough，不保留兼容层 | D5；短信模板审核（人工） |
| P1-2 活动群聊 | 先做 spike：验证 `GroupChatCard` 在 Taro 4.2.1 + 插件 1.2.2 + 2.0 架构下能否编译和渲染。通过后，组织者在 web 为活动绑定小红书群，报名成功的用户看到入群卡片。注意规范 7.1，不能诱导加群 | spike；可能涉及 migration，需人工合并 |
| P1-3 Hacker Start 1024 小红书版 | campaign 页和发现页入口卡迁到小红书，去掉剪贴板复制邮箱、志愿者网申入口。押金报名依赖 P3，所以在小红书上只能做宣传（D6）。时间点：10-24 启动，发版审核 3–5 个工作日，还隔着国庆假期，最晚要在 9-30 前提审，或者接受节后提审的风险 | D6 |
| P1-4 专业号运营（人工） | 专业号主页挂小程序入口（最多 3 个）；官方笔记挂载小程序（需专业号认证，并遵守规范 7.4） | 专业号认证 |

### P2 · 闪念间分层迁移

顺序是：本人面 → 公开面 → 写面。每一批单独提审。

| 切片 | 内容 | 依赖 |
|---|---|---|
| P2-0 平台确认（人工） | 发工单问清：公开许愿树、金句墙、附议是否需要社交类目，允许展示成什么形态 | — |
| P2-1 内容安全平台无关化 | 没有微信身份的写入一律设为 `review_required`，先人工审核再挂树（复用现有 `hidden_at` 链路，不引入新供应商）；量上来以后再换第三方机审。这项同时补上 web 端的既有缺口（I5） | 后端 |
| P2-2 IA 与能力单源 | 小红书 Tab 加上「闪念间」；依赖 X-1 | X-1 |
| P2-3 本人面 | 迁移首程旅程、长廊 / 我的卡、场次、今天的你。替换 3 处用户可见的微信文案：`flashback-corridor/index.tsx:797`、`flashback-event/index.tsx:194`、`domain/flashback-journey.ts:130` | P2-2 |
| P2-4 服务端出图 | 卡片图改由服务端生成 https 图片，同时用于三处：保存相册（下载后保存）、分享卡片 `imageUrl`、发笔记的 `media-info`。先做渲染器选型 spike：比如 web 的 `next/og` 或后端出图；中文字体的许可要过合规门，OFL 不在允许列表里，需要先开 issue 确认 | 许可确认 |
| P2-5 公开面 | 公开卡页、金句墙、许愿树浏览 | P2-0 |
| P2-6 写面 | 写愿望、附议；回响提醒走 P1-1 的短信通道。有一个边界问题要一起处理：`wish_echoes.ex:304-307` 只要入队数大于 0 就标记回响机会已使用，而只有小红书身份的附议者，任务入队后会因模板缺配被丢弃，机会白白消耗。P1-1 删掉 xhs 通知链路后这类用户不再入队，问题自然消失；改走短信时，要按短信是否实际入队来标记 | P2-0、P2-1、P1-1 |
| P2-7 发笔记 | 闪念卡一键发成小红书笔记（标题 ≤20 字，正文 ≤1000 字，带 `#闪念间`）；「活动打卡笔记」同理。复用 P1-2 的 2.0 架构 spike 结论 | P2-4 |

### P3 · 端内交易（依赖资质，人工先行）

| 切片 | 内容 |
|---|---|
| P3-0 资质（人工） | ① 核验主体类型（民办非企业单位和事业单位不能开通交易）；② 企业专业号认证（600 元/次，每年年审）；③ 找对接人开白类目，候选是「软件工具-实用工具-预约/报名」或「活动组局」；④ 就押金形态发工单确认（规范 6.6.5 有「收保证金、押金」的欺诈示例）；⑤ 确认支付渠道（通用担保可能只支持支付宝） |
| P3-1 后端渠道 | 新增 `xhs_guarantee` provider：下单、取 pay token、同步订单状态、退款、`PAY_RESULT` / `REFUND_RESULT` 加密回调、对账 worker；与现有 `:wechat_jsapi` 并列（`backend/lib/cgc_2046/payments/provider.ex:40`） |
| P3-2 前端支付页 | `order-pay` 增加小红书分支，调用 `requestGuaranteeOrderPayment`。**押金同意门的两道门原样复用**（`miniprogram/AGENTS.md`「资金动作门」不变量），支付调用点仍只保留一处 |
| P3-3 押金 | 用「下单 + 到场退款」模拟：沿用核销即退（`backend/lib/cgc_2046/admission/attendance.ex` 的 `enqueue_deposit_refund`），退款换成小红书退款接口 |
| P3-4 边界 | 线上课程不走小红书支付（小程序没有虚拟支付，iOS 上不能出现购买入口） |

### 不迁移

- `openclacky`：导流红线。
- 工作台审批、扫码核销、主理人订阅、生成邀请码：组织者面，按原则①保留在微信端和 web。等出现真实的「只用小红书的组织者」时再重新评估。
- `volunteer-apply`：web 已有 `apply/volunteer`；在小红书端做表单留资有规范 6.13.1 的风险；选 PDF 需要客户端 9.2 以上。
- 「朋友圈」分享入口：由 P2-7 的发笔记替代。

### 横切工程

- **X-1 平台能力单源（新立 ADR-0019）**：ADR-0016 第 6 条写的是「等第一个第二平台立项时，再由真实需求决定缝在哪」，现在就是这个时间点。
  - 做法：用一个纯数据模块（例如 `miniprogram/src/domain/platform-matrix.ts`）声明各平台的页面清单、Tab 清单和能力位（支付、订阅、Canvas 2D、发笔记、群聊、扫码）。`app.config.ts`、`AppTabBar`、入口路由和页面门控都从这里读。
  - 替换现在散落在 `src/` 下的 16 处 `process.env.TARO_ENV` 判断；P0-4 那类「导向未注册页面」的问题就是这种散落造成的。
- **X-2 Canvas 依赖面**：P2-4 之后，`CheckInQr` 是否也改为服务端出图，等 P2-4 选型后一并决定；在那之前，退回显示 6 位码是可以接受的兜底。
- **X-3 Taro 插件停更**：锁定插件 1.2.2。新能力通过原生 `xhs.*` 加 `canIUse` 调用，类型声明写在 `miniprogram/types/`。P1-2 和 P2-7 共用同一个 2.0 架构 spike。
- **X-4 验收**：小红书没有 automator 可用的 e2e，每个切片都要更新小红书真机清单。判据照旧下沉到 domain 层，用 `node --test` 钉住。
- **X-5 scene 传参**：小红书扫码进入时 scene 怎么传到页面，文档没写（UNVERIFIED）。P0-5 只做手输邀请码；扫码加入等真机验证后再做。
- **X-6 消息推送接收端点**：P1-2（用户加群通知、群聊人数已满）、P2-7（笔记发布回调）、P3-1（支付结果、退款结果、交易能力切换）都依赖后台的「域名与推送 → 消息推送」。
  - 后端要先做一个接收端点：GET 做地址校验（token、timestamp、nonce 按字典序拼接后取 sha1，与 signature 比对，通过后原样返回 echostr）；POST 接收 JSON 密文并解密。
  - 平台 5 秒内收不到响应就断开，并重试 3 次。所以端点要先回 `success`，再交给 Oban 异步处理，处理逻辑按消息做幂等。
  - Token 和 EncodingAESKey 按 `XHS_MP_SECRET` 的方式走部署密钥。
  - 端点部署上线后才能去后台填写，否则地址校验通不过。三个依赖切片里谁先开工，谁就负责建这个端点。

## 五、依赖与排期

```
P0-1(后端,先上) ──┐
P0-2..P0-6(一次小红书发版) ──┼─→ P1-1 ──→ P2-6
                  └─→ X-1 ──→ P2-2 ──→ P2-3 ──→ P2-5(需 P2-0)
P1-2 spike ──→ P2-7(需 P2-4)
P3-0(人工,周期不可控) ──→ P3-1 ──→ P3-2/P3-3
```

- 每次小红书发版需要 3–5 个工作日审核，国庆期间（10-01 至 10-07）要预留缓冲。
- P3 的周期取决于资质审批，工程部分不要提前开工。如果资质最终拿不到，小红书端的定位就收敛为「免费活动 + 种草 + 闪念间」，这本身也是一个可以接受的终态。

## 六、待决策

| # | 问题 | 选项 | 推荐 |
|---|---|---|---|
| D1 | 资质到位之前，小红书端的收费 / 押金场次怎么处理 | a. 详情可看，报名按钮置灰，中性说明「本端暂未开放缴费报名」；b. 发现页直接过滤掉；c. 维持现状（有巡检风险） | a |
| D2 | 小红书端的 Tab 结构 | a. 发现 / 我的（我的报名收进「我的」，与微信端一致；P2 之后加闪念间）；b. 发现 / 我的报名 / 我的 | a |
| D3 | 是否启动交易资质申请 | 是 / 否（否则 P3 搁置） | 先做 P3-0 ①，核验主体类型，再决定 |
| D4 | 闪念间公开面是否先向平台发工单确认 | 是 / 否 | 是；确认前只迁本人面 |
| D5 | 小红书用户的触达是否改走短信 | 是（需申请短信模板，按条计费）/ 否 | 是 |
| D6 | Hacker Start 1024 是否在 10-24 前上小红书（押金报名仍不可用，只做宣传） | 是 / 否 | 由运营判断宣传价值 |
| D7 | 隐私政策小红书版的正文 | 需法务确认；源档 `docs/合规上架/隐私政策.md`、web 页、小程序页三方同步 | — |
| D8 | 本次过审的小红书版本号，以及小红书小程序的 ICP 备案号 | 需人工提供 | — |

## 七、风险

| 风险 | 影响 | 应对 |
|---|---|---|
| 过审后的平台巡检 | 「网页端支付」文案、不能退出、没有隐私政策，都可能导致下架 | P0-3 / P0-5 |
| 登录修复在真凭据上仍有不确定性 | 官方文档写 AES-128，却注明密钥 24 字节，自相矛盾 | 以官方 Java 示例为准，真机验证 |
| 公开 UGC 类目不符（6.5.3） | 闪念间公开面可能上不了小红书 | 等 P2-0 结论，本人面不受影响 |
| 交易资质拿不到 | P3 永久搁置 | 按「五」里的终态定位收敛 |
| Taro 插件停更 | 新能力只能靠原生调用 | X-3 |

## 附录：平台证据索引（2026-09-25 快照）

- 获取调用凭证（POST `{appid, secret}`，7200 秒，最多两个同时有效）：https://miniapp.xiaohongshu.com/doc/DC010382 （已独立核对原文）
- code2Session：https://miniapp.xiaohongshu.com/doc/DC414670 ；开放数据解密：https://miniapp.xiaohongshu.com/doc/DC591932
- 担保支付 `requestGuaranteeOrderPayment`：https://miniapp.xiaohongshu.com/doc/DC034783 ；FAQ（类目开白、主体限制）：https://miniapp.xiaohongshu.com/doc/DC556847 ；类目细则：https://miniapp.xiaohongshu.com/doc/DC274768
- 管理规范（6.5.3 / 6.6.5 / 6.13.1 / 7.1 / 7.9 / 第九条）：https://miniapp.xiaohongshu.com/doc/DC246380 ；常见拒绝情形：https://miniapp.xiaohongshu.com/doc/DC312529
- 不限量小程序码：https://miniapp.xiaohongshu.com/doc/DC164497 ；URL Link：https://miniapp.xiaohongshu.com/doc/DC274658 ；scanCode：https://miniapp.xiaohongshu.com/doc/DC571125
- 分享：https://miniapp.xiaohongshu.com/doc/DC382121 ；post-note-button：https://miniapp.xiaohongshu.com/doc/DC743133 ；群聊组件：https://miniapp.xiaohongshu.com/doc/DC532545
- canvas（无 2D）：https://miniapp.xiaohongshu.com/doc/DC045922 ；chooseSystemFile：https://miniapp.xiaohongshu.com/doc/DC777404
- 客服消息（唯一的服务端下行通道）：https://miniapp.xiaohongshu.com/doc/DC234367
- 消息推送（事件回调、地址校验、5 秒超时 / 重试 3 次）：https://miniapp.xiaohongshu.com/doc/DC577113 ；业务域名（仅供 web-view 使用）：https://miniapp.xiaohongshu.com/doc/DC508424 ；网络使用说明（服务器域名不做限制）：https://miniapp.xiaohongshu.com/doc/DC452619 （以上三份已独立核对原文）
