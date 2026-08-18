# 分享 + URL Scheme 正式实现计划（plan 011 spike 后续）

> 输入：docs/01-定稿设计/微信分享与深链-spike结论.md（下称 spike 文档）——D1-D5 已拍板全选 A（2026-08-18 plan owner），本计划引用其结论，不重新调查。
> 状态：待人工批准（SOP plan mode）
> 日期：2026-08-18
> 前置依赖：无（spike 原型已随 PR #229 合入 develop）

## 目标

交付微信端活动分享主链路：**聊天卡片分享**（用户侧转发 → event-detail 详情页）+ **URL Scheme 深链基础设施**（生成/存储/复用/到期刷新，活动发布时预生成，供未来短信/邮件/H5 中转渠道消费）。

### Out of scope（spike D3-A/D4-A/D5-A 拍板 + 既有边界）

- 朋友圈分享（`useShareTimeline`）——单页模式禁用报名 CTA，D3-A 不进 v1
- 裁剪端（tt/xhs）分享——Taro 映射未核实（U5）/xhs 无等价 API，D4-A 不进 v1
- GraphQL mutation/query 面——D5-A：scheme 由后端内部触发，不做管理面
- 短信/邮件渠道与 Android H5 中转页——只交付 link 基础设施，渠道另立项
- 朋友圈素材后台、服务端 title 合规护栏（spike §4.1 列为实现计划外增强）

## Current-state 证据（2026-08-18 develop 核实）

- `backend/lib/cgc_2046/miniprogram/url_scheme.ex` — spike 原型已合入：`create_event_link(event_id, kind, expires_at)`（SDK `UrlScheme.create_scheme`，errcode 保真，30 天约束留给调用方）。注意参数名 `event_id` 对 kind=course 名不副实（P2 顺手改名 `target_id`，调用方仅测试）
- `miniprogram/src/pages/event-detail/index.tsx` — `useRouter` 读 `router.params.id/kind`（:21-22，kind 三态回落 event）；`useShareAppMessage` 已挂（:56-59，title=`item?.title`，loading 态 undefined → 回落小程序名，P4 补兜底）
- `miniprogram/src/app.tsx:7-12` — `useLaunch` 只处理 `query.scene` → join（Workspace 邀请链路）；scheme/分享 path 由微信客户端直接导航打开页面（冷启动无需 app.tsx 处理）；**热启动缺口**（F05 复发面）：`Taro.onAppShow` 未挂（spike §3.2）
- 存储先例：`backend/lib/cgc_2046/miniprogram/code.ex` — upsert action（:50-53，identity `:unique_invitation_platform` + `upsert_fields`）
- 信号先例：`backend/lib/cgc_2046/workflows/research_instantiator.ex` — 订阅 `event.launched`/`course.launched` patterns；Oban 异步先例 `Cgc2046.NotificationSubscriber`
- 活动结束时间：Event 有 `endsAt`（event.ended 信号先例）；Course 无统一 endsAt（P2 兜底见决策 D-3）

## 设计（引用 spike 拍板）

| 决策 | 拍板 | 本计划落地 |
|---|---|---|
| D1-A 到期失效 | `expire_time = min(活动结束 + 缓冲, 30 天)` | 生成服务层 clamp（缓冲 7 天；官方 85401 上限 30 天）。**实施口径修正（writer07 决策回传，owner 拍板 2026-08-18）**：Event/Course 实际均无 endsAt 字段（plan current-state 有误），两 kind 统一以 `registration_deadline` 为 clamp 代理 = `min(registration_deadline + 7d, now + 30d)`，nil → now+30d |
| D2-A 同 event 复用 | 按 Code upsert 先例 | 新 Ash 资源 `ShareScheme`，UK (target_kind, target_id, platform)，未过期命中即复用、过期重生成覆盖 |
| D5-A 内部触发 | 无 GraphQL 面 | 订阅 `event.launched`/`course.launched` → Oban 异步预生成（决策 D-1 请批准） |
| 分享卡片 | spike 已挂 | P4 仅补 title 兜底文案 |

**拒绝的替代**（均见 spike §6 各 B 项）：永久 scheme（10 万上限不可删）；每次新生成（逼近 50 万/日配额）；朋友圈/裁剪端进 v1（成本见 spike §1.2/§1.3）。

### 安全边界（spike §5 已论证，实施不得突破）

- scheme query / 分享 path 只含 `id`+`kind`（公开内容标识），**永不**携带 token/邀请凭据/手机号/openid
- 与 join/admit 一次性凭据链路完全隔离（scene 不进分享 path）
- 请求日志红线沿用 WechatRequester `debug: false`；title 兜底文案不得含平台字样（零导流门禁扫产物静态文本）

## 影响面

- 后端新增：`backend/lib/cgc_2046/miniprogram/share_scheme.ex`（资源）、`share_scheme_service.ex`（生成/复用/clamp）、`backend/lib/cgc_2046/workflows/share_scheme_instantiator.ex`（信号订阅）+ Oban worker、迁移 `*_create_miniprogram_share_schemes.exs`
- 后端修改：`url_scheme.ex`（参数改名）、`application.ex`（children + 订阅器）、`config/config.exs`（Oban 队列，若新增）
- 前端修改：`event-detail/index.tsx`（title 兜底）、`app.tsx`（热启动，若 D-2 批准）
- 文档：`CONTEXT.md`（ShareScheme 词条）、`miniprogram/e2e/REAL_DEVICE_CHECKLIST.md`（spike §8 行落档）
- 数据库：新表 `miniprogram_share_schemes`（无数据回填，lazy 生成）；无既有表变更；无生产数据写入

## Phases（测试先行，每 phase 独立可验证）

### P1 存储资源（后端）
测试先行：资源测试（upsert 幂等：同 (kind,id,platform) 二次 upsert 更新不重复插入；identity 冲突路径）——模式照 `backend/test/cgc_2046/miniprogram_code_test.exs`。
实现：`ShareScheme` 资源（attributes: `target_kind` atom[event|course]、`target_id` uuid、`platform` atom[:wechat]、`openlink` string、`expires_at` utc_datetime；identity `:unique_target_platform`；upsert action 照 code.ex:50-53）+ 迁移。
验证：`MIX_ENV=test mix test test/cgc_2046/miniprogram/share_scheme_test.exs` 全绿。

### P2 生成服务（后端）
测试先行（Tesla.Mock，008 模式）：命中未过期记录 → 返回复用且**零外呼**（复用生效的关键断言）；过期 → 重新生成并 upsert 覆盖；`expires_at` clamp（目标 endsAt+7d > now+30d 时截断为 now+30d；endsAt 缺失 → now+30d）；errcode 44990/40002 传播不落库。
实现：`ShareSchemeService.fetch_or_generate(target_kind, target_id)`；`url_scheme.ex` 参数改名 `target_id`（调用方仅测试同步）。
验证：`mix test test/cgc_2046/miniprogram/share_scheme_service_test.exs` 全绿。

### P3 触发点（后端）
测试先行：信号发布 → Oban job 入队（subscriber 测试）；job 执行 → `fetch_or_generate`（Tesla.Mock）；重复信号幂等。
实现：`ShareSchemeInstantiator` 订阅 `event.launched`/`course.launched`（patterns 照 research_instantiator.ex:24）→ Oban job 异步预生成（外呼不进信号同步路径）；`application.ex` children 注册。
验证：`mix test`（subscriber + worker 用例）全绿。

### P4 前端两小项
测试先行：路由判定纯函数（query 含 id → event-detail 跳转；含 scene → 既有 join 链路；scene 优先）入 `tests/`（node --test 清单）。
实现：a) 分享 title 兜底 `item?.title ?? 'CGC · 精选活动'`（无平台字样）；b)（D-2 批准则做）`app.tsx` 挂 `Taro.onAppShow`：热启动 query 带 id+kind 且当前不在 event-detail → reLaunch/navigateTo event-detail，与 pendingScene 链路互斥（scene 优先）。
验证：`pnpm typecheck && pnpm test:unit` 全绿。

### P5 验收收尾
全量：`mix compile --warnings-as-errors && mix format --check-formatted && mix test`；`pnpm typecheck && pnpm test:unit && pnpm build:weapp && pnpm build:tt && pnpm build:xhs && pnpm check:diversion`（零导流门禁零命中）。
文档：CONTEXT.md 词条（ShareScheme：微信 URL Scheme 分享链接，UK (target_kind,target_id,platform)，到期失效 min(endsAt+7d, 30d)，活动发布预生成）；REAL_DEVICE_CHECKLIST.md 增 U4（主体权限 D 级必查）/分享卡片/scheme 冷热启动行（spike §8 体例）。

## 检查与回滚

- 构建/运行时：全量 mix test + 前端三端构建；CI 4 job 预期全绿
- 功能：分享卡片真机项进 checklist（U1 title 截断实测）；scheme 真机需线上正式版（官方限制：scheme 只能生成已发布页面）
- 安全：query 无敏感值（P2 测试断言请求体仅 id/kind）；零导流门禁；日志红线沿用
- 回滚：整链路纯增量（新表/新模块/两行前端）——`git revert` 单 PR 可回；迁移 down drop table；分享挂载还原 = title 兜底一行删（useShareAppMessage 本体保留无害）
- 并发：upsert identity 承担并发互斥（同 code.ex 先例）；Oban job 幂等（fetch_or_generate 天然幂等）

## Signoff criteria

- P1-P5 验证命令全绿；U4 真机核实行已落 checklist 且标注「上线前 D 级必查」
- PR（1 个，含全部 phases）经独立评审 PASS 后合并——按仓库惯例走 advisor-plans 流水线或直接 review

## 待人工决策（批准本计划即视为拍板）

- **D-1 触发点**：推荐 `event.launched`/`course.launched` 预生成（信号总线现成先例、无 GraphQL 面、渠道未来直接取）；备选：纯 lazy（v1 无外部调用方 → 等于死代码，不推荐）
- **D-2 热启动补齐**：推荐进 v1（`Taro.onAppShow` ~15 行 + 纯函数测试，闭合 F05 复发面）；备选：推迟立 issue（接受「已打开小程序再点链接不跳详情」）
- **D-3 Course 结束时间兜底**：推荐固定 `now+30d`（Course 无统一 endsAt）；备选：接入 Course 元数据（需额外调查，违反「不重新调查」边界）
