# 小程序订阅消息模板申请：flashback_wish_echo（许愿树回响通知）

> 状态：**模板已选用落地（2026-09-22），代码接入已完成（2026-09-23，02745ac6，
> 槽位对齐实抄 thing1/thing4）**——标题「活动反馈推送提醒」，模板 ID `<模板ID>`
> 已配 GitHub secret 与 `miniprogram/.env.prod`。§8 checklist 留作执行记录；
> 注意实做 data_key 与 §2/§8 建议口径有偏差（现用 `content_preview` + 固定引导语，
> `wish_title`/`echo_summary` 待 Echo 批字段定稿后切换），以 service.ex 为准。
> 本文档保留为作业单存档：内容设计、平台规则、操作步骤、以及「拿到模板 ID 后」
> 的代码接入 checklist。安全红线：真实模板 ID 只存在于公众平台后台与 GitHub
> secret / gitignore 的 `.env.prod`，本文档与 issue 一律用 `<模板ID>` 占位
> （AGENTS.md 内部标识符红线）。

## 1. 用途与阻塞关系

- 需求源：`docs/plans/2026-09-21-1550-requirements-flashback-voices-wishes-plan.md`
  R31 / R36 —— 用户在小程序许愿树对愿望「附议 · 我能出力」时勾选「接收回响通知」
  （默认勾选，`wx.requestSubscribeMessage` 授权）；运营发布 Echo（回响）时向该愿望
  的订阅者发送「你附议的愿望有新回响」订阅消息。
- **硬阻塞**：模板 ID 未就位 → 附议表单的「接收回响通知」勾选按 fail-closed 隐藏，
  回响触达只剩 Web/邮件兜底；Echo 批发送（R36）前必须就位。
- 通道语义：小程序一次性订阅（一次授权换一条消息）；Web 游客无订阅通道，产品上
  引导去小程序（R19 拍板）。长期订阅仅对政务民生/医疗/交通/金融/教育类目开放，
  本小程序类目（预约/报名、会展服务）**只能走一次性订阅**（微信官方
  subscribe-message-overview，2026-09-22 查证）——与全部既有 26 键一致。

## 2. 建议数据契约（接入时按此对齐，最终以实施 plan 定稿为准）

| data_key | 建议槽位类型 | 内容 | 约束 |
|---|---|---|---|
| `wish_title` | thing | 愿望标题/内容摘要 | ≤20 字符，超长由 `thing/1` 截断 |
| `echo_summary` | thing | 回响摘要（R20：指向具体回应，不得呈现「愿望已实现」） | ≤20 字符 |
| `notice`（可选） | thing | 引导文案，如「点击查看愿望的回响详情」 | ≤20 字符 |

- 不建议 time/date 槽位：回响是异步批发送，时间语义弱；少一个时间类型槽位
  可避开 date/time 类型差异坑（参见 `event_schedule_changed` 的 date3 教训）。
- `job_meta_keys` 建议 `["echo_id", "idempotency_key"]`；`unique: :default`、
  `stale: nil`（对齐 `volunteer_application_*` 条目形状）。

## 3. 平台规则摘要（官方文档，2026-09-22 查证）

来源：`developers.weixin.qq.com` 小程序订阅消息开发指南 + `subscribeMessage.send`
参数限制表 + 选用模板接口（`api_addwxanewtemplate`）。

- 获取模板 ID 两条路：**公共模板库选用**（即时生效）或**申请新模板**（审核约
  1–7 个工作日，站内信通知结果）。
- 关键词组合 2–5 个；场景描述 ≤15 字。
- 标题与关键词必须体现「服务主体 + 行为 + 场景」，宽泛词（内容/提示/项目）会被拒；
  示例值必须与关键词语义匹配。
- 中文内容必须选 **thing** 类型，选 character_string 会被驳回。
- 参数类型长度：thing ≤20 字符（中英数符号）；character_string ≤32；phrase ≤5 汉字
  （枚举倾向，慎用于长文案）；number ≤32 位纯数字；time 24 小时制支持年月日与
  「~」时间段；date 年月日（支持带时刻）；amount 1 币种符号+≤10 位数字。
- 发送限制：一次性订阅一次授权一条；下发上限 1kw/日（未开通支付）。
- 授权约束：`wx.requestSubscribeMessage` 一次最多 3 个 tmplIds、必须由用户点击
  触发（本仓 `subscription.ts` 既有设计已遵守）。

## 4. 路径 A（优先尝试）：公共模板库选用

基于 2026-09-17/18 对公共模板库的全量扫描（本小程序可用类目「预约/报名 /
会展服务」下全部 54 个模板），**标题含许愿/回响/评论/回复/留言语义的模板为 0**；
「名称 + 说明」双 thing 的中性模板大多已被本仓占用（同标题仅可选用一次）。
**2026-09-22 复扫（53 模板）：回响/愿望类仍为 0，且实测本小程序后台无全新标题
申请通道（`tmpladd` 无 tid 为空白页、「我的模板」页无申请按钮）→ 走选用制**。
最终选用全库语义最近似的「**活动反馈推送提醒**」（反馈≈回响），挑关键词
「活动名称 + 备注」双 thing，场景说明「附议愿望的回响通知」，即时生效。
若发现以下形态的库内新模板即可改选、跳过第 5 节审核周期：

- 标题含「回响 / 回复 / 回应 / 愿望」语义；且
- 关键词含 ≥2 个 thing 类槽位（愿望标题 + 回响摘要）。

选用时挑关键词操作与既有 26 键同流程（配置关键词 → 场景说明 → 提交）。

## 5. 路径 B（预计主路径）：新模板申请文案

公共库无匹配时，在「公共模板库 → 找不到合适的关键词？点击申请」入口提交：

- **模板标题**：`愿望回响通知`
  （备选：`回响通知`；避免「实现/达成」措辞——R20 禁止暗示愿望已实现）
- **服务场景描述**（≤15 字）：`附议愿望的回响通知`（9 字）
- **关键词字段表**（3 个，全部 thing，提交时类型选「事物」）：

| # | 关键词名 | 类型 | 示例值（须与关键词语义匹配） | 对应 data_key |
|---|---|---|---|---|
| 1 | 愿望内容 | 事物 thing | 在大理办一场山村图书角 | `wish_title` |
| 2 | 回响摘要 | 事物 thing | 场地已由社区活动中心提供 | `echo_summary` |
| 3 | 温馨提示 | 事物 thing | 点击查看回响详情并报名 | `notice` |

- **过审要点**（按官方驳回规则反推）：
  1. 标题含「服务主体（愿望）+ 行为（回响）+ 场景（通知）」，非宽泛词；
  2. 示例值与关键词严格对应（愿望内容配愿望句、回响摘要配回应句）；
  3. 中文一律选「事物」类型，勿选「字符串」；
  4. 场景说明强调**用户主动订阅**（附议时勾选）且属社区活动服务通知，
     非营销群发——若被要求补充说明，按此口径在审核反馈里答复。
- 提交后 1–7 个工作日出结果；过审后模板出现在「我的模板」，ID 形如
  `<模板ID>`（43 字符）。

## 6. 管理员操作步骤（mp.weixin.qq.com，小程序账号）

1. 登录 → 左侧「功能 → 订阅消息 → 公共模板库」；
2. 按 §4 复核：有匹配 → 选用并挑关键词（愿望内容/回响摘要/温馨提示 或最近似），
   场景说明填「附议愿望的回响通知」；无匹配 → 库内「找不到合适的关键词？点击申请」
   按 §5 文案提交，等审核（1–7 工作日）；
3. 过审/选用后进「我的模板 → 详情」，**实抄**：完整模板 ID（43 字符）+ 每个槽位的
   实际编号与类型（历次经验：编号非顺序分配，如 thing2/thing5/thing7，**必须实抄
   不得推断**）；
4. 把「模板 ID + 槽位编号表」交给实施方（回报到 tracking issue，公开面用
   `<模板ID>` 占位 + 私密渠道传真值）。

## 7. env / secret 配置（拿到 ID 后，编排者执行）

| 位置 | 键 | 值 |
|---|---|---|
| GitHub secret（repo CodingGirlsClub/cgc_2046） | `WECHAT_MP_TEMPLATE_FLASHBACK_WISH_ECHO` | `<模板ID>` |
| `miniprogram/.env.prod`（gitignore，本地/构建机） | `CGC_WECHAT_TEMPLATE_FLASHBACK_WISH_ECHO` | `<模板ID>` |

键名生成规则：场景键 `flashback_wish_echo` → SCREAMING_SNAKE
（`FLASHBACK_WISH_ECHO`）；后端前缀 `WECHAT_MP_TEMPLATE_`、小程序构建前缀
`CGC_WECHAT_TEMPLATE_`（与既有 26 键同律）。真实 ID 不进任何 tracked 文件。

## 8. ID 到手后的接入 checklist

### 后端（7 触点）

1. `backend/lib/cgc_2046/notifications/notification_worker.ex`：`@notification_types`
   追加条目 `flashback_wish_echo`（形状对齐 `volunteer_application_submitted`：
   `data_keys: ["wish_title", "echo_summary"]`、`job_meta_keys: ["echo_id",
   "idempotency_key"]`、`unique: :default`、`stale: nil`）；
2. `backend/lib/cgc_2046/notifications/service.ex`：新增
   `render(:wechat, "flashback_wish_echo", ...)` 子句——**槽位编号按管理员实抄值写**
   （勿按 thing1/thing2 推断；示例：若实抄为「愿望内容=thing4 / 回响摘要=thing6 /
   温馨提示=thing8」则按实抄写三行）；
3. `backend/config/runtime.exs`：prod `:miniprogram_templates` wechat 段追加
   `"flashback_wish_echo" => System.get_env("WECHAT_MP_TEMPLATE_FLASHBACK_WISH_ECHO")`；
4. `backend/config/config.exs`：dev/test 占位值
   `"flashback_wish_echo" => "dev-wechat-flashback-wish-echo"`；
5. `.github/workflows/deploy.yml`：fail-closed `for v in ...` 名单 + `env:` 映射
   **两处**追加 `WECHAT_MP_TEMPLATE_FLASHBACK_WISH_ECHO`；
6. `backend/config/deploy.yml`：kamal `env.secret` 追加同名键；
7. `backend/.env.example`：追加空值键（带「许愿树回响通知」注释）。

### 后端测试（2 处守卫必改，否则红）

8. `backend/test/cgc_2046/notifications/template_allowlist_test.exs`：
   `@expected_size 26` → `27`（注释同步「26 → 27」）；
9. `backend/test/cgc_2046/notifications/notification_worker_test.exs`：若 registry
   键集断言需同步（按该文件现有形状）。

### 小程序（5 触点，三处双射 + 守卫 + 触点）

10. `miniprogram/config/index.ts`：`WECHAT_SCENARIOS` 追加 `'flashback_wish_echo'`；
11. `miniprogram/src/domain/models.ts`：`SubscriptionScenario` 联合同步；
12. `miniprogram/src/domain/subscription.ts`：`ALL_SCENARIOS` 同步 + 触点数据：
    授权时机 = 附议表单「我能出力」提交按钮（用户点击触发，单 tmplId ≤3 约束
    天然满足）；「覆盖缺口」注释无需新增条目（Web 游客无通道是产品决策 R19）；
13. `miniprogram/tests/subscription-build.test.mjs`：
    `EXPECTED_SCENARIO_COUNT = 26` → `27`；
14. 附议表单解锁：`flashback_wish_echo` 场景在构建期注入成功后，「接收回响通知」
    勾选由 fail-closed 隐藏转为可见（按 volunteer 六键同款剔除逻辑，反向解锁）。

### 部署与验证

15. GitHub secret 配置（§7）先于 deploy（fail-closed 名单缺 secret → deploy 第一
    分钟红）；
16. `cd backend && mix test template_allowlist_test` + `cd miniprogram && pnpm
    test:unit`（186 → 187+ passed，双射断言在内）；
17. 真机验证消耗真实用户订阅配额，需单独人工授权（同既有纪律）。

## 9. 历史教训引用（写渲染子句前必读）

- 槽位编号非顺序分配：`event_qualification_manager`（thing2/thing5）、
  `event_moderator_removed`（thing1/thing5）、volunteer 六键
  （thing7/thing5/thing6 等无一命中 thing1/2/3）——**以详情页实抄为唯一真源**；
- phrase 类型（≤5 汉字枚举）不可承载长文案（`审核结果提醒` 的 phrase1 教训）；
- date 与 time 类型格式不同（`event_schedule_changed` date3 vs `报名成功通知`
  time47）——本文档 §2 已建议不选时间槽位规避。
