# Plan 019 · 活动管理面验收加固（#127 收尾：测试补齐 + UX 加固）

- 日期：2026-08-15
- 状态：待评审
- 决策依据：双 scout 取证（Scout019a/019b，2026-08-15）+ 用户拍板（范围=测试+UX 加固；visibility 维持 D9 随时切换）
- 关闭目标：#127（主体已落地，本 plan 补验收与 UX 后完整关闭）

## 1. 背景与取证结论（与 #127 issue 叙述的差异）

**#127 正文已过时**：issue 写作时（2026-08-13）称「无 GraphQL mutation、无 web 入口」。HEAD（`0f2abac`+`d76cba8`）取证结论：

| #127 验收项 | HEAD 现状 | 证据 |
|---|---|---|
| Event/Course 五 mutation 后端 | ✅ 已存在 | `backend/lib/cgc_2046/events/event.ex:203-470`（create/update/launch/close/cancel actions + CAS `487-503`）、GraphQL `547-563`；Course 同构 `course.ex:172-468, 512-528` |
| Owner/Admin 权限面 | ✅ | `event.ex:519-521`（create/update = Owner/Admin ∪ PlatformAdmin）；`policies/workspace_actor_is_owner_or_admin.ex:1-42` |
| web 列表/详情/新建 | ✅ 完整实现 | `web/components/offering-pages.tsx`：列表 `126-180`、详情 `227-416`、not-found `468-475`、元数据编辑 `518-589`、生命周期 `639-681`、新建表单 `754-895` |
| GraphQL client | ✅ 10 合约 | `web/lib/graphql/events.ts:167-359`；wrappers `web/lib/events.ts:124-229` |
| 小程序 | 裁剪不做 | `miniprogram/e2e/DOUYIN_REDNOTE_CHECKLIST.md:14-18` |
| 生命周期级联 | 属 #124，部分已有 | worker/reaper/sponsorship ended（`event_lifecycle_worker.ex:1-77`、`research_run_reaper.ex:1-75`、`sponsorship_ended_subscriber.ex:1-71`）；Enrollment 既有记录不级联取消是 #124 边界 |

**用户纠正已核实**：AshAdmin ops 面是平台 Admin 专属（`router.ex:64-77` + `platform_admin_plug.ex:1-30` + `platform_admin_live_auth.ex:1-82`），但普通 Owner/Admin 经 web/GraphQL 可完整管理活动——「单一 Owner 无法创建活动」已不成立。

**真实剩余差距**（本 plan 交付面）：
1. UI 行为零测试：新建提交/保存元数据/可见性保存/launch/close/cancel 的 mutation 调用链无点击级断言（`offering-pages.test.tsx:1-30, 95-136` 仅 mock wiring + 页头/错误态；`events.test.ts:43-84` 仅合约字符串与纯函数）。
2. 不可逆操作无确认：close/cancel 按钮一键直达（`offering-pages.tsx:666-681`）。
3. 错误文案直透：save 失败直接展示 `e.message`（`342-363, 365-397, 400-416`），可能暴露 GraphQL 原文。
4. 多余请求：非管理者详情页也发 `fetchPendingCount`（`307-319`，UI 隐藏却仍请求）。

## 2. 已拍板决策

- **D-vis（用户裁决 2026-08-15）**：visibility 维持现行 D9 语义——随时双向切换（含 open 后）。#127 acceptance checkbox「open 后不可改 visibility」判过时；关 issue 时注明裁决，不改代码。
- **范围**：测试补齐 + UX 加固，一个小 PR 完整收 #127。不新建页面/组件/合约。

## 3. High-Level Technical Design

### U1 UI 行为测试补齐（`web/components/offering-pages.test.tsx` 扩展 + 新建页测试）
对既有 mock wiring 补点击级调用链断言（Event/Course 双 kind 表驱动）：
1. **新建**：`OfferingNewPage` 填表 → submit → 断言 `createOffering` 以正确变量调用（kind 映射 MUTATION_BY_KIND）→ 成功跳转详情路由；非 manage 渲染拦回不调用（`754-814` 拦回分支）。
2. **保存元数据**：manage 视角改 title/capacity/deadline → saveMeta → `updateOffering` 变量断言 → 成功后表单态复位；失败分支显示错误（接 U2 文案）。
3. **保存可见性**：`saveVisibility` → `updateOffering` 仅 visibility 变量；双向切换两 case（D9 语义钉住：open→public 与 public→open 均可）。
4. **生命周期**：draft→launch、open→close、open→cancel 三链 → `transitionOffering(kind, id, transition)` 断言 → 成功局部状态更新；终态无按钮渲染断言。
5. **失败分支**：mock reject → 断言错误展示且 busy 复位。

### U2 UX 加固
1. **不可逆确认**（close/cancel）：点击先弹确认（复用仓库现有确认模式——writer 查 `invite-batch-panel.tsx` 禁用确认与 settings 页既有 confirm 交互，取一致模式；无统一组件则轻量内联确认条 + 二次点击，不引新依赖）。launch 不加确认（可逆性高）。
2. **错误文案友好化**：`saveVisibility/saveMeta/runTransition` 三处 catch 改用提取器模式——参照 `invite-batch-panel.tsx:116-128`（`friendlyCreateError` 正则映射 + 兜底文案）与 `requests.ts:192-194`（GraphQL errors 首条 message 提取 + 非 GraphQL 兜底）。抽 `web/lib/events.ts` 或组件内私有 helper：GraphQL message → 已知模式（duplicate slug 等 writer 按后端约束补）→ 映射文案；未知 → 通用「保存失败，请重试」/「操作失败，请重试」。不透传原始 message。
3. **移除多余请求**：`fetchPendingCount` 仅 manage 视角调用（`307-319` 挪进 manage 条件；普通成员/匿名不发）。

### U3 e2e（agent-browser，结构断言）
1. Owner 新建 draft → 详情可见「发布（开放报名）」→ launch → 状态徽章 open。
2. close 确认条出现 → 二次确认 → 状态 closed；cancel 同构。
3. 保存失败路径（如 capacity 非法）→ 错误文案非 GraphQL 原文（断言不含 `Argument`/`Input` 等后端词）。
4. 普通成员详情页 network 静默（断言无 pendingApprovals/enrollments count 之外的 pending count 请求——用 request 计数断言）。

## 4. 文件清单

- `web/components/offering-pages.tsx`（U2 三处 + U2.3 请求条件）
- `web/components/offering-pages.test.tsx`（U1 扩展）
- `web/lib/graphql/events.test.ts`（不动，合约已覆盖）
- e2e 证据进 PR 描述（不留测试文件，按仓库惯例）

后端零改动；SDL 零 diff。

## 5. 验收标准

1. U1 五组调用链断言全绿（Event/Course 双 kind）。
2. close/cancel 有确认交互；launch 无。
3. 三处 save 失败展示映射文案，未知错误走兜底，不含原始 GraphQL message。
4. 非 manage 视角零 pendingCount 请求。
5. `pnpm typecheck/lint/test/build` 全绿；backend 不动（无重跑必要，CI 兜底）。
6. e2e 四组结构断言过。
7. #127 关闭评论注明：主体先于本 plan 落地（015/016 增强链）；D-vis 裁决维持 D9；acceptance checkbox 过时。

## 6. 实施顺序（writer 契约）

U1 测试 → U2 三点 → U3 e2e → 自查（web 全套；backend 不涉及）→ 本地 commit 不 push → 报告 `/tmp/cgc_2046-writer19-report.md`（STATUS/FILES/TESTS/E2E/RISKS/NEXT）。

## 7. Assumptions（writer 验证，冲突即停）

1. `createOffering/updateOffering/transitionOffering` mock 已在测试文件 wiring（`1-30`），扩展为调用断言无结构障碍。
2. 仓库有可复用确认交互模式（invite-batch 禁用确认 / settings 页）；无则内联确认条（aria 完备）。
3. `fetchPendingCount` 挪 manage 条件不影响 manage 视角 pending 角标（015-A4 引入的 count 面板在 manage 块内）。
4. 017/018 合并后 `offering-pages.tsx`/权限词汇可能有 rebase 漂移——writer 在 018 合并后的 develop 基线上实施，冲突即停报告。
