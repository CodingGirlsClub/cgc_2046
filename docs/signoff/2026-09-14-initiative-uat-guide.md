# UAT 指南：Initiative（hackerstart1024）人工验收

- 日期：2026-09-14
- 范围：`docs/plans/2026-09-13-1159-feat-initiative-plan.md` 的 R1–R19（U1–U11）
- 环境：本地 dev（backend :4001，web :3001），数据在 `cgc_2046_dev`

## 账号（密码统一 `Uat2046!pass`）

| 角色 | 账号 | 用途 |
|---|---|---|
| A1 平台管理员 | `uat-admin@cgc2046.local` | `/admin/initiatives` 管理面、规则锁死项传播、审计 |
| A2 Workspace Owner | `uat-owner@cgc2046.local` | 2046 社区内建场挂载、编辑、主理人增删、改期 |
| A3 主理人（非成员） | `uat-moderator@cgc2046.local` | 长沙站主理人；现场核销（扫码/输码）与押金当场退已交付（#508 最小集），离线码/脱敏名单/作品审核等完整能力属 #508 后续 |
| A4 参与者 | `uat_learner_a@`…`uat_learner_h@cgc2046.uat` | 公开页报名、我的报名、自助取消 |

注意：浏览器同一 profile 同时只能保持一个登录态，换角色请先在右上角退出或直接重新登录（新登录会覆盖 cookie）。

## 预置数据矩阵

Initiative `hackerstart1024`（open；押金 ¥69 锁死、18+ 锁死、最小成班 8 默认、截止 72h 默认）：

| 场次 | 城市 | 状态 | 预期徽章 |
|---|---|---|---|
| 1024-changsha-01 | 长沙市 | open，3 人确认 | 还差 5 人成班 |
| 1024-hangzhou-01 | 杭州市 | open | 还差 8 人成班 |
| 1024-online-01 | 线上 / 待定 | open | 还差 8 人成班 |
| 1024-shanghai-01 | 上海市 | open，8 人确认，已过截止 | 已成班（Qualified 计数 1） |
| 1024-beijing-01 | 北京市 | cancelled（未达阈值自动取消） | 已取消 |
| 1024-shenzhen-01 | 深圳市 | closed | 已结束（留档） |
| 1024-internal-01 | 长沙 | draft + workspace | 公开页不出现 |
| 1024-draft-01 | — | draft public | 公开页不出现 |

另有 `maker-recap-2025`（closed 届，1 场 closed 留档场）用于归档/列表态。

重置数据：`cd backend && mix run priv/repo/uat_seed_initiative.exs`（幂等，可重复；`priv/repo/uat_check.exs` 查看矩阵）。

## 分角色验收清单

### 匿名访客（不登录）

1. 打开 `http://localhost:3001/initiatives/hackerstart1024`：四项计数（城市 6 / 场次 6 / 报名 13 / 已成班 1），按城市分组，徽章矩阵与上表一致。
2. 点任意场次卡片 → 进入既有 Event 详情；长沙站详情显示「Enrollment closes 10/10」（开场前 72h 继承）。
3. 北京站（已取消）/深圳站（已结束）详情只读，无报名写入口。
4. 未登录在开放场次点报名 → 引导登录并带 next 回跳。
5. `/en` 与 `/zh-CN` 两语言路由都可达同一 slug。

### A4 参与者（uat_learner_a 登录）

6. 从公开页进入长沙站 → 详情显示报名徽章与「还差 N 人成班」。
7. 我的报名 `/participations`：看到已有确认报名；点「Cancel enrollment」→ 确认弹窗 → 名额释放，公开页计数与徽章即时变化（还差人数 +1）。
8. 上海站（已过截止）：自助取消只释放名额、不退款（无退款动作）。

**寻路回归（本轮修复，重点回归）**：

- 匿名打开长沙站详情 → 点**导航条**「登录」（不是报名区链接）→ 登录后必须回到长沙站详情页，不得落在工作台。
- 登录后公开页导航条出现「我的报名」；工作台侧边栏（如 /w/uat）出现「我的报名」→ 均直达 `/participations`。

边界提示：押金链路已交付（押金制计划 U1–U11）——押金场报名落 `payment_pending` 并生成唯一活跃押金单，支付完成落 `confirmed` 并出 6 位核销码；主理人核销当场全额退、报名保持 confirmed；活动结束 T+48h 未核销的 `paid` 押金单结算为 `forfeited`（押金不退、留作平台收入）。押金制的验收以 `docs/plans/2026-09-14-1357-feat-event-deposit-plan.md` 为准；本指南各条目仍只验收规则来源与名额/状态语义。18+ 表单属 #510。

### A2 Owner（uat-owner 登录，工作台 2046）

9. `/w/2046/events/new`：Initiative 下拉（聚焦时加载）选 hackerstart1024，建草稿 → 编辑页显示「Initiative rules in effect」（押金 ¥69 / 18+ / 最小成班 8）。
10. 草稿期可换挂/摘除；已发布场次 Initiative 下拉禁用（不挂不摘），但名称回显正确。
11. 主理人卡片：列表（建场创建者默认在列）、按用户 ID 指派、移除即时生效；closed/cancelled 场次同样可操作。
12. 改期（starts_at/ends_at 同改）→ 保存成功；有效报名者收到 event_schedule_changed 通知投递（durable outbox）。注意：默认截止规则不随改期级联（KTD2 挂载快照），需要时手动改截止时间；锁死规则才会跟随。

### A1 平台管理员（uat-admin 登录）

13. 非管理员登录访问 `/admin/initiatives` → 被守卫导回工作台（不渲染数据）。
14. `/admin/initiatives`：列表（open/draft/closed 状态与操作按钮）；新建草稿；无四项规则的草稿点「开放」→ 内联报「missing all four rules」，列表保留。
15. 编辑 hackerstart1024：四项规则值与锁态正确渲染；改押金金额（锁死项）→ 全部 9 个挂载场即时生效，审计页 `/admin/audit` 有脱敏记录（只含 initiative_id/rule_key/locked）；改回 ¥69。
16. 最小成班人数（默认项）改 10 → 已挂载场保持 8，新建挂载场初值 10（AE2）。验证后改回 8。

### MCP / agent 通道（可选）

17. 平台管理员 MCP 工具：list/get/create/update/open/close Initiative 均走 Confirmation 两段式（首段 pending 不落库，confirm 才生效）；公开读 `get_public_initiative` / `list_public_initiatives` 与 Web 同口径。
18. 主理人 MCP：`list_event_moderators` / `assign_event_moderator` / `remove_event_moderator`。

### 小程序（微信/抖音/小红书）

19. discover 显示 open 与 closed 两个 Initiative 入口；点入 hackerstart1024 详情 → 城市分组/计数/徽章与 Web 一致；点场次卡进既有 event-detail；已取消场显示「已取消」且无报名写入口。
20. 三平台构建已验证（`pnpm build:weapp/tt/xhs` + 零导流检查）；真机预览用各平台开发者工具导入 `miniprogram/dist/` 对应产物。

## 本轮 agent 自测发现并修复的问题

| # | 问题 | 处置 |
|---|---|---|
| 1 | 公开页 closed 事件徽章错显「还差 N 人」（Web 自行推导漏 closed 分支，与小程序口径不一致） | 改用后端 `qualificationBadge` 投影，补 `initiatives.closed` 文案与组件测试 |
| 2 | Web 缺主理人管理 UI（U7 计划内交付物） | 新增 EventModeratorsCard（列表/按 ID 指派/移除）+ GraphQL 契约层 + 4 条组件测试 |
| 3 | `Moderators.remove` 生产路径崩 `NoPrimaryAction`（destroy 未设 primary；GraphQL 与 MCP 都中招，旧测试绕过域层） | destroy 设 primary + `not_found_error?: false` 语义；测试改走域入口并补 not_found/越权用例 |
| 4 | 已发布挂载场的 Initiative 下拉显示 "No Initiative"（选项聚焦才加载） | 已挂载时提前加载，closed Initiative 也保留回显 |
| 5 | Event 编辑页看不到规则生效值（锁死项不可见） | 新增只读规则摘要块（GET_EVENT 补押金/年龄/人数字段） |
| 6 | 管理页规则锁 checkbox 用 render 期旧值，会覆盖未失焦的文本编辑 | 改读 textarea 当前 DOM 值 |

记录在案的既有边界（非本轮缺陷）：取消事件的 confirmed 报名保留记录且仍可手动取消（既有取消语义）；默认截止规则不随改期级联（KTD2 设计）；押金制（收取 / 核销当场退 / no-show 结算）已交付并回写 #509，18+ 表单仍属 #510。
