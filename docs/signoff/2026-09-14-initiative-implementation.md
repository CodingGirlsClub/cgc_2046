# 签收：Initiative（倡导活动）实施验收

- 日期：2026-09-14
- 关联：docs/plans/2026-09-13-1159-feat-initiative-plan.md（implementation-ready）
- 验收人：agent 执行，记录同

## 验收结论

**通过（代码验收）。** 计划 U1–U11 全部落地，Backend/Web/小程序三端门禁全绿，浏览器结构与交互验收 PASS。生产环境 101 场导入与真实微信渠道通知审核按计划属后续上线验收，不在本文档范围。

## 门禁证据

| 门禁 | 结果 |
|---|---|
| backend `mix test` | 2042 passed（含 Initiative 资源/边界/公开投影/GraphQL/MCP/生命周期/通知/退款链路） |
| backend `mix format --check-formatted` / `mix compile --warnings-as-errors` | 通过 |
| backend `mix ash_postgres.generate_migrations --check` | 通过（snapshot 与 migration 同步） |
| backend `mix cgc2046.gen_error_codes_contract --check` / `mix cgc2046.check_licenses` | 通过（92 deps） |
| web `pnpm test`（含 check:i18n） | 964 passed；zh-CN/en 1760 keys 对齐 |
| web `pnpm typecheck` / `pnpm lint` / `pnpm build` / `pnpm check:licenses` | 通过（lint 0 error；1582 packages） |
| miniprogram `pnpm check:graphql` / `typecheck` / `test:unit` | 通过（85 tests；introspection ok） |
| miniprogram `build:weapp` / `build:tt` / `build:xhs` / `check:diversion` | 三平台构建通过；tt/xhs 零导流检查通过 |

## 浏览器验收（ego-browser，dev 环境，种子 Initiative hackerstart1024）

结构断言（DOM/数值，不经视觉模型）：

- `/initiatives/hackerstart1024`：hashtag/名称/描述渲染；四项计数 Cities 3 / Events 3 / Participants 3 / Qualified 0 与种子数据一致；城市分组 杭州市、线上 / 待定、长沙市 正确；徽章数值正确（长沙站 3 确认 → "5 more needed"，其余 0 确认 → "8 more needed"）。
- 卡片链接 → `/events/1024-changsha-01` 导航成功；详情页渲染开始/结束/报名截止（继承 72h 规则：10/13 开场 → 10/10 截止）、venue 四键、报名入口（匿名引导登录）。
- Event 详情页成班徽章：长沙站显示 "5 more needed to qualify"（R11）。
- `/admin/initiatives`（平台管理员登录态）：列表渲染状态与操作；创建草稿成功；无规则草稿点「开放」→ 内联展示后端错误 "invalid initiative transition or missing all four rules" 且列表保留（错误分支）；编辑面板四项规则值与锁态（押金/18+ 锁死，阈值/截止默认）正确渲染。

E2E 中发现并修复的问题（均有回归测试）：

1. 公开投影裸 SQL 返回 NaiveDateTime，GraphQL `:datetime` 序列化 MatchError → 抬升 UTC DateTime。
2. `listInitiatives` 未加载 rules，NotLoaded 被 Absinthe 包成单元素列表致 non-null 违规 → 显式 load 并映射 admin 行。
3. Web Event 详情页缺成班徽章（R11 缺口）→ 新增 QualificationBadgeTag。
4. 管理页操作错误误报 "Failed to load" 并清空列表 → 内联错误消息、列表保留。
5. 规则面板非受控 `defaultValue`/`defaultChecked` 不随异步数据更新 → 待 rules 归属当前编辑目标后再挂载。
6. `admin.initiativeRule_*` 文案缺失渲染原始 key → 补齐双语。

## 公开 DTO 脱敏核对

公开投影 DTO 不含 workspace_id、capacity 原值、订单/退款/no-show 明细；报名数为 enrollments 实时聚合（R10 口径），非 events.confirmed_count 展示列。平台管理员规则变更审计元数据只落 `initiative_id`/`rule_key`/`locked`，不含规则值。

## 遗留（按计划归后续）

- #508 核销本体、#509 到场退款规则、#510 完整 18+ 表单、#513 城市主理、#505 配套课程、作品墙、批量建场。
- 生产 101 场导入、运营脚本、真实微信渠道通知审核：另走上线验收。
