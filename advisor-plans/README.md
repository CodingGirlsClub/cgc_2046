# 小程序改进审计与实施方案

由 `improve` 技能维护。两批审计共用本索引：

- **第一批（2026-08-09，commit `f1fd4aa`）**：001-005，全部 DONE——历史记录见文末。
- **第二批（2026-08-18，commit `048c9f8`，deep 审计）**：调研已安装依赖 `wechat_sdk`
  0.19.0 的功能面，对照微信小程序栈（backend 集成 + miniprogram 前端）产出 006-011。

执行者应按下表顺序读取对应方案，严格遵守每份方案的 STOP 条件，并在完成后更新状态。
`plans/`（仓库根）已被仓库 SOP 占用，因此本目录（`advisor-plans/`）是唯一方案目录。

## 第二批：执行顺序与状态（2026-08-18）

| [006](./006-fix-frontend-payment-path.md) | 前端收费链路两修：payment_pending 解析 + 裁剪端支付跳转守卫 | P1 | S | — | DONE（PR #204 merged；advisor F1b 扩 scope 修 enrollment-result 待支付分支） |
| [007](./007-wechat-pay-client-startup.md) | 微信支付真实链路可用：SDK client 启动（证书+Finch）+ webhook_base_url 门禁 + adapter 直接测试 | P1 | M | — | DONE（PR #221 merged；决策回传补 SDK 硬性 api_secret_v2_key，运维需配 WECHAT_PAY_API_V2_KEY） |
| [008](./008-miniprogram-wechat-sdk-adoption.md) | Miniprogram.Client wechat 分支接 SDK：token 缓存/重试/自愈 + 落页修正 + errcode 保真 | P1 | M | — | DONE（PR #220 merged；宿主 WechatRequester 适配，零外呼红线结构性成立） |
| [009](./009-phonecode-login-contract.md) | getPhoneNumber 新契约（phoneCode）：微信侧 SDK 直取手机号 | P1 | M | 008 | DONE（PR #224 merged；advisor F1 修 tt/xhs 平台 gate；部署纪律：后端先于前端） |
| [010](./010-docs-realignment.md) | 文档三修：ICP 模板数对齐 8 键、总纲 §7.3 支付下架、平台矩阵替代文档 | P2 | S | — | DONE（PR #207 merged；ICP 实为 9 键/端 + learning_stagnation 漂移如实记录，P2 后续项「通知配置面漂移收敛」待立） |
| [011](./011-share-url-scheme-spike.md) | 【Spike】微信原生分享 + URL Scheme 深链契约与配额核实 | P2 | M | 008 | TODO |

状态值：`TODO`、`IN PROGRESS`、`DONE`、`BLOCKED（附一行原因）`、
`REJECTED（附一行理由）`。

### 依赖与并行说明

- 006 / 007 / 010 相互独立，可三路并行。
- 008 是 009 与 011 的前置（两者复用其 `WechatClient` SDK 宿主）；008 与 007 并行安全
  （不同文件族，唯一交叠是都参照 wechat_pay.ex 的 persistent_term 指纹缓存 pattern）。
- 007 建议先跑 Step 1 特征化测试（红）再动生产代码——它同时是 008/009 的测试模式先例。

## 第二批：Vetted findings（全部经 advisor 亲自复核源码）

| ID | 类别 | Finding 与证据 | 影响 | Effort | 修复风险 | 置信度 | 方案 |
|---|---|---|---|---|---|---|---|
| F-24-01 | correctness | WechatPay 只 `build_client`（Module.create，pay.ex:144-161）从不 `start_client`——`Refresher.Pay.make_sure_certs`（仅 Supervisor init 调用）与命名 Finch 池（`:"#{client}.Finch"`）都不存在：`Certificates.get_cert` 恒 nil（验签恒败）、首次外呼 noproc exit；`application.ex` children 无任何 SDK 进程。 | 真实密钥环境下单/退款/回调验签/对账全链路不可用；「真实小额验收」里程碑必失败 | M | MED | HIGH | 007 |
| F-24-02 | correctness | `parseEnrollmentStatus` 白名单缺 `payment_pending`（miniprogram/src/domain/format.ts:62-65），而 real.ts:251/295 用它解析服务端返回。 | 付费报名提交后前端抛「未知状态」显示提交失败（服务端已占位）；「我的报名」列表同崩 | S | LOW | HIGH | 006 |
| F-24-03 | correctness | register-form 无平台守卫 redirectTo order-pay（register-form/index.tsx:74-76）；该页仅 weapp fullPages 注册；同入口 my-enrollments:132-142 已有正确守卫先例。 | 裁剪端（tt/xhs）付费报名跳转失败、用户卡死 | S | LOW | HIGH | 006 |
| F-24-04 | correctness | 订阅消息 page 硬编码 `pages/mine/index`（backend client.ex:90/107/124）、小程序码 page 硬编码 `pages/invite/index`（client.ex:186/200/223）——两页面在三端 app.config.ts 均不存在（实际为 profile/join）。 | 三端通知点击与扫码入口全部「页面不存在」 | S | MED | HIGH | 008 |
| F-24-05 | correctness/可观测 | 微信 200+JSON 错误体被压平：`parse_binary_image` 只认 binary body（client.ex:235-238），JSON 错误体落入 `parse_platform_failure` → `{:error, {:platform_http_status, 200}}`，errcode（43101/41030/45009 等）全丢；三个 send/token 分支同模式。 | 平台真实失败不可诊断（HTTP 200 被当错误码） | S | LOW | HIGH | 008 |
| F-24-06 | correctness | `notify_url` 对 nil `webhook_base_url` 做 `Path.join` 崩溃（wechat_pay.ex:192-194）；`configured?`（:143-146）五键不含它，prod runtime.exs:277-290 该键无默认值。 | prod 半配置首单/退款 500（FunctionClauseError 而非清晰拒绝） | S | LOW | HIGH | 007 |
| F-24-07 | tests | WechatPay adapter 零直接测试：test.exs:61-65 全量注入 Fake，`Provider.for(:wechat_*)` 永不解析到真实 adapter；providers_test.exs:69-100 测的是 SDK 原语非本项目编排。 | F-24-01/06 所在层 0 覆盖 | M | LOW | HIGH | 007 |
| F-24-08 | tech-debt | wechat 分支 token 现取现用无缓存（client.ex:132-140）+ `retry: false`（:513）+ 无 40001 自愈；SDK 的 Refresher（30min 预刷+60s 重试）/TokenChecker（5min 探测）/ETS/Retry×3 全部闲置（`config :wechat` 零配置）。 | 每次推送/出码多耗一次 token 配额；token 失效即全线失败；网关抖动零重试窗口 | S-M | LOW | HIGH | 008 |
| F-24-09 | correctness/migration | phoneCode 契约缺失：前端 `event.detail.code` 死字段（platform/index.ts:38-41 硬性要求 encryptedData/iv；operations.ts:131-141 无 phoneCode 变量），后端 action 两参数 `allow_nil?: false`（strategies/miniprogram.ex:101-114）；真机清单 N1 已挂账。SDK `UserInfo.get_phone_number/3`（user_info.ex:130）可免 session_key 直取。 | 现代基础库真机登录必挂（新用户无法登录） | M | MED | HIGH | 009 |
| F-24-10 | docs/ops | ① ICP 清单写微信模板 ×3（ICP备案材料清单.md:27-28），config 实际 8 键且 runtime.exs 全量 `fetch_env!`（config.exs:66-104）——按清单备料上线即 boot 失败；② 总纲 §7.3 仍列支付为二期（00-CGC平台设计总纲.md:227-229），ADR-0007 已定为 v1；③ 实施计划文档消失，隐私草案:4/app.config.ts/ci.yml/checklist 的「§2」引用悬空。 | 上线准备踩坑；决策依据丢失 | S | LOW | HIGH | 010 |
| F-24-11 | correctness | `workspaceName` 硬编码「公开工作台」（real.ts:97），Catalog 查询未选该字段。 | 多公开工作台时发现页 Club 同名塌缩 | S | LOW | HIGH | —（未排期） |

## 第二批：Direction 选项（不与缺陷排序）

| ID | 方向 | 证据与收益 | Effort | 风险/取舍 | 置信度 | 方案 |
|---|---|---|---|---|---|---|
| D-24-A | 微信原生分享 + URL Scheme | 分享 API 全仓零使用（grep 核实）；SDK `UrlScheme.create_scheme/3` 现成；scene 链路已过真机验收（app.tsx→join）；承接第一批 D03。微信生态获客最高杠杆面。 | M（spike） | scheme 有配额/有效期约束；裁剪端零导流红线；分享 scene ≠ 邀请 scene 不能复用消费逻辑 | HIGH | 011 |
| D-24-B | 通知 feed query + 落点统一 | checklist 挂账「后端尚无通知 feed（F9）」；profile 已有本机通知 UI；完成后订阅消息落点有权威落页（与 F-24-04 联动）。 | M-L | 后端通知持久化是新面；需产品定保留期 | HIGH | —（未排期） |
| D-24-C | 内容安全 msgSecCheck | SDK `Security.msg_check` 现成；报名表单强制收集自由文本 reason 且无审核通道——小程序上架对 UGC 有合规要求。 | M | 需先定哪些字段入审、失败处置、平台各自接口差异 | MED | —（未排期） |
| D-24-D | V2 视频号 / V3 企业微信 | 仅 user_identity.ex:7 unionid 注释预留；SDK WeChat.Work 全家桶同库可用。 | — | 未立项；企微与「网站=管理中枢」边界需 product 拍板 | MED | —（仅信号） |

## 第二批：Findings considered and rejected

- 「登录页『保存 7 天登录状态』文案与实现不符」：服务端 JWT TTL 在仓库内不可证伪
  （strategies/config 均无显式 TTL 值），无法断言文案错误——纯文案 nit，不立 plan。
- 「webhook 验签缺时间戳新鲜度窗」：SDK 自家 `Pay.EventHandler` 同样不做窗口检查
  （event_handler.ex:141-150 亲核，无时间比较）；controller 的 (provider, event_id)
  唯一索引已把重放折为幂等重复。降为可选加固，不单独立项。
- 「复用 SDK Pay.EventHandler plug 替换手写 verify_webhook」：与 Provider behaviour
  seam + controller 幂等落库/Oban 同事务架构相抵（KTD3/KTD4 既定设计），by-design 不迁。
- 「code2session 迁 SDK」：现有 Req 实现带三平台信封归一与完备测试，SDK 只覆盖 wechat
  且 code2session 不依赖 access_token——迁移收益为零，保持现状。
- 「sdk refresher 对 tt/xhs 的推广」：SDK 不覆盖 tt/xhs，抽象共享层属过度设计。
- 手机号明文+sensitive 存储、通知本地存储、裁剪端零导流、v1 无 UI 组件库：第一批已定
  settled/rejected，不再重议。

## 第一批（2026-08-09）：执行顺序与状态（历史，全部收口）

| Plan | 标题 | Priority | Effort | Depends on | Status |
|---|---|---|---|---|---|
| [001](./001-license-gate-fail-closed.md) | 让许可证门禁按白名单 fail-closed | P1 | M | human 先裁定现有 Zlib 声明 | DONE |
| [002](./002-diversion-gate-fail-closed.md) | 让零导流产物门禁真实、完整且 fail-closed | P1 | S | — | DONE |
| [003](./003-add-toutiao-project-config.md) | 补齐抖音工程配置并隔离本机项目标识 | P1 | S | — | DONE |
| [004](./004-establish-api-contract-tests.md) | 建立 API/认证边界自动化测试 | P1 | M | 001, 002 | DONE |
| [005](./005-make-auth-state-atomic.md) | 让认证状态提交原子化并隔离账号本地数据 | P1 | M | 004 | DONE |

第一批的完整 findings 表（F01-F18）、direction 选项（D01-D04）、依赖说明与
considered-and-rejected 记录见 git 历史（本文件 2026-08-09 版本）；其中仍未修复且
未被第二批覆盖的项：F05（scene 前台恢复）、F06（审批摘要字段）、F10（三端分支测试）、
F11（codegen diff 门禁）、F12（死依赖）、F15（release gate）、F16（check:ci 漂移）、
F17（隐私披露 vs 实际收集）、F18（ICP 无来源条目）——后续审计先查此清单防重报。
