# Plan 010: 三处文档错位修正——ICP 模板数对齐 config、总纲 §7.3 移除已落地的支付条目、回收消失的小程序实施计划引用

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 048c9f8..HEAD -- docs/00-CGC平台设计总纲.md docs/合规上架/ miniprogram/src/app.config.ts .github/workflows/ci.yml miniprogram/src/components/AppTabBar/index.tsx miniprogram/src/pages/my-enrollments/index.tsx miniprogram/e2e/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `048c9f8`, 2026-08-18

## Why this matters

三处文档与代码的错位，都会在「上线准备」时刻造成真实成本：

1. ICP/上架清单告诉运维「微信订阅消息模板 ×3、抖音 ×2」——但 config 实际要求微信 **8** 个
   模板 ID 且 `runtime.exs` 对全部 8 键 `fetch_env!`（缺配即 boot 失败）。按清单准备
   会在上线部署时当场 boot 崩溃，且漏掉的恰好是缴费三模板。
2. 总纲 §7.3 仍把「支付」列为二期——ADR-0007（2026-08-15 拍板）已把收费做成 v1 可选
   路径且代码全量落地（payments 域 U1-U14）。读总纲的人会得出「支付未做」的错误结论。
3. 小程序实施计划文档（`plans/2026-08-08-002-miniprogram-implementation-plan.md`）已从
   仓库消失，但隐私草案、app.config.ts、CI workflow、checklist 仍引用它的「§2 平台矩阵 /
   §2 裁剪原则 / §5 Phase 5」——引用悬空，多端裁剪这条产品红线的书面依据不复存在。

## Current state

- `docs/合规上架/ICP备案材料清单.md:27-28`（节选）：

```markdown
- [ ] 微信订阅消息模板 ID ×3（approval_result / approval_reminder / event_reminder，plan §9 Q3）
- [ ] 抖音订阅消息模板 ID ×2（approval_result / event_reminder，裁剪端）
```

  真实契约：`backend/config/config.exs:66-104` 的 `:miniprogram_templates` 微信 8 键 =
  approval_result / approval_reminder / event_reminder / learning_stagnation /
  speaker_completed / **payment_succeeded / refund_succeeded / refund_failed**；
  `backend/config/runtime.exs:154-158` 等处对全部 8 键 `System.fetch_env!`（缺一即启动失败）。
  抖音 2 键（approval_result / event_reminder）与清单一致。

- `docs/00-CGC平台设计总纲.md:227-229`（§7.3 二期清单首项）：

```markdown
### 7.3 二期清单
支付（赞助 #2：状态机插 payment_pending → paid）、批量邀请候选池（邀请 #3：复用 InviteBatch quota 机制）、...
```

  事实：`docs/adr/0007-payment-architecture.md`（已接受，2026-08-15）+ 
  `docs/plans/2026-08-15-024-feat-payment-loop-plan.md`（U1-U14）已把报名缴费做成 v1
  可选路径；`backend/lib/cgc_2046/payments/` 全量存在。**注意**：§4.2「赞助 v1 不收款」
  仍然正确（赞助收款确实还是二期），错位仅限 §7.3 这一条把「支付」整体列为二期。

- 悬空引用（`plans/2026-08-08-002-miniprogram-implementation-plan.md` 已不存在，根
  `plans/` 目录为空）：
  - `docs/合规上架/隐私指引草案.md:4`：
    `> 关联：plans/2026-08-08-002-miniprogram-implementation-plan.md §5 Phase 5 交付物 #3`
    （§3/§6 还有两处同源引用，动手时 grep 全文件）
  - `miniprogram/src/app.config.ts:1-3`：`// 裁剪端（抖音/小红书）：2 Tab 漏斗——发现/我的报名 + 流程页，无管理/协作功能（§2 平台矩阵）`
  - `miniprogram/src/components/AppTabBar/index.tsx:19` 附近：同源「§2 平台矩阵」引用
  - `miniprogram/src/pages/my-enrollments/index.tsx:132` 附近：同源引用
  - `.github/workflows/ci.yml:126` 附近：`零导流红线（§2）` 类注释
  - `miniprogram/e2e/DOUYIN_REDNOTE_CHECKLIST.md:3,17,45`：`§2 裁剪原则`
  - `miniprogram/scripts/check-no-diversion.mjs:3`：文件头注释同源

  精确行号以 grep 为准（见 Step 3 的命令）。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 全部引用点 | `grep -rn "2026-08-08-002" . --include="*.md" --include="*.ts" --include="*.tsx" --include="*.mjs" --include="*.yml"` | 列出待改点 |
| 悬空段引用 | `grep -rn "§2 平台矩阵\|§2 裁剪\|§5 Phase 5" .` | 列出待改点 |

（纯文档/注释改动，无编译测试；前端文件只动注释，跑一次 typecheck 兜底。）

## Scope

**In scope**:
- `docs/合规上架/ICP备案材料清单.md`
- `docs/00-CGC平台设计总纲.md`（仅 §7.3 一行及其上下文）
- `docs/合规上架/隐私指引草案.md`（仅悬空引用行）
- `miniprogram/src/app.config.ts`、`miniprogram/src/components/AppTabBar/index.tsx`、
  `miniprogram/src/pages/my-enrollments/index.tsx`（仅注释行）
- `.github/workflows/ci.yml`（仅注释行）
- `miniprogram/e2e/DOUYIN_REDNOTE_CHECKLIST.md`、`miniprogram/scripts/check-no-diversion.mjs`（仅注释/引用行）
- 新建 `docs/01-定稿设计/小程序多端平台矩阵.md`（承载原「§2」内容的替代文档）

**Out of scope**:
- `backend/config/config.exs` / `runtime.exs`——文档对齐代码，不是反过来。
- ADR-0007、payment plan、CONTEXT.md——已是正确状态。
- 总纲 §4.2 赞助条目——内容仍正确。
- `miniprogram/e2e/REAL_DEVICE_CHECKLIST.md` 的验收项内容（只在 Step 3 顺带核对其
  引用是否悬空，悬空则同法处理）。
- 隐私草案的实质内容（手机号、留存期等）——只动引用行。

## Git workflow

- Branch: `advisor/010-docs-realignment`
- Commit style 先例：`docs(compliance): ICP 模板数对齐 config 8 键 + 总纲 §7.3 支付下架 + 平台矩阵替代文档 (#NNN)`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: ICP 清单模板数对齐

`docs/合规上架/ICP备案材料清单.md:27-28` 改为与 `config.exs:66-104` 的 8 键逐一对应
（微信 ×8 列全键名并标注「缺任一 → runtime fetch_env! 启动失败」，抖音 ×2 不变），
并把「plan §9 Q3」这类指向现存文档的出处改为 `docs/plans/2026-08-15-024-feat-payment-loop-plan.md`
（缴费三模板的真实出处）或删去出处。

**Verify**: `grep -n "模板 ID" docs/合规上架/ICP备案材料清单.md` → 微信行含 8 个键名
且与 `grep -n "approval_result\|payment_succeeded\|refund_succeeded\|refund_failed\|learning_stagnation\|speaker_completed" backend/config/config.exs` 的键集合一致。

### Step 2: 总纲 §7.3 支付条目下架

`docs/00-CGC平台设计总纲.md:229` 删除「支付（赞助 #2：状态机插 payment_pending → paid）、」
这一项，并在 §7.3 标题下加一行括注：
`（支付已于 2026-08-15 升为 v1 可选路径，见 ADR-0007 与 docs/plans/2026-08-15-024；赞助收款仍在二期，见 §4.2）`
——保留可追溯性，读者不会再去旧位置找。

**Verify**: `grep -n "7.3" docs/00-CGC平台设计总纲.md` 邻近行不再含裸「支付（赞助 #2」，
含 ADR-0007 括注。

### Step 3: 平台矩阵替代文档 + 引用回收

1. 新建 `docs/01-定稿设计/小程序多端平台矩阵.md`，内容最小但完整（把丢失的「§2」
   语义从现行 enforce 产物反推成文）：
   - 平台矩阵表：weapp 全量 4 Tab 11 页；tt/xhs 裁剪 2 Tab 7 页（页面清单照抄
     `miniprogram/src/app.config.ts` 的 cutPages/fullPages，标注「以 app.config.ts 为准」）；
   - 裁剪原则三条（从 DOUYIN_REDNOTE_CHECKLIST.md 与 advisor-plans rejected 区反推）：
     裁剪端无管理/协作功能（无 workspace/order-pay/profile/openclacky）、零跨端导流
     （CI `check:diversion` fail-closed 强制）、JSAPI 支付为 weapp 专属（裁剪端付费
     引导网页端）；
   - 溯源行：`> 本文档重建自已删除的 plans/2026-08-08-002 §2（2026-08 实施计划）；
     现行强制产物为 miniprogram/src/app.config.ts、.github/workflows/ci.yml 的
     三端编译 + 零导流门禁。`
2. 全部悬空引用改指新文档：
   - 隐私草案 `:4`（及文件内同源引用）→ `docs/01-定稿设计/小程序多端平台矩阵.md`
     或直接指向 backend 源文件（`backend/lib/cgc_2046/accounts/user.ex` 的引用是
     实文件，保留）；
   - `app.config.ts:1` / `AppTabBar:19` / `my-enrollments:132` 注释 →
     `（docs/01-定稿设计/小程序多端平台矩阵.md）`；
   - `ci.yml` / `check-no-diversion.mjs` / `DOUYIN_REDNOTE_CHECKLIST.md` 的
     「§2 裁剪原则 / 零导流红线（§2）」→ 同上。
   改动仅限注释与 markdown 引用行，不动任何逻辑。

**Verify**:
- `grep -rn "2026-08-08-002" . --include="*.md" --include="*.ts" --include="*.tsx" --include="*.mjs" --include="*.yml"` → **零命中**（git 历史仍可追溯，无需保留文件名）
- `grep -rn "§2 平台矩阵\|§2 裁剪" .` → 零命中
- `cd miniprogram && pnpm typecheck` → exit 0（注释改动兜底）

## Test plan

纯文档/注释改动，无新测试。验证 = 上述三个 grep 零命中 + typecheck。改动过的 TS/TSX
文件不进任何行为路径（仅注释），`pnpm test:unit` 跑一次兜底即可。

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -rn "2026-08-08-002" .`（含上述 include 集）零命中
- [ ] `grep -n "payment_succeeded" docs/合规上架/ICP备案材料清单.md` 命中
- [ ] `docs/01-定稿设计/小程序多端平台矩阵.md` 存在且含 cutPages/fullPages 两清单
- [ ] `cd miniprogram && pnpm typecheck` exit 0
- [ ] `git status` 无 in-scope 外改动；`advisor-plans/README.md` 状态行已更新

## STOP conditions

Stop and report back (do not improvise) if:

- `backend/config/config.exs` 的模板键集合与「Current state」列出的 8 键不符
  （以 config 为准更新清单，但若键数差异大——如新增了清单完全没提的场景——报告）。
- 发现「§2」引用指向的不是已消失的实施计划（存在另一份同编号文档）——报告，勿盲改。
- 总纲在 drift check 后已有 §7.3 修订（重复修复）。
- CI 文件里的引用处于 YAML 字符串值（而非注释）中——改动可能影响 workflow 解析，
  报告后再动。

## Maintenance notes

- 平台矩阵文档声明「以 app.config.ts 为准」——后续增删页面时记得同步该文档；
  复审 PR 若改了 app.config.ts，把此文档列入 checklist。
- ICP 清单其余条目（价格、时窗）无来源依据的问题属前次审计 F18，仍未修——本计划
  只修模板数这一处硬错位。
- 新文档放在 `docs/01-定稿设计/` 与其他定稿设计同级；若 domain docs 约定
  （docs/agents/domain.md）要求同步 CONTEXT.md 词条，不在本计划范围（那是 DOC-02
  的 M 级任务，未排期）。
