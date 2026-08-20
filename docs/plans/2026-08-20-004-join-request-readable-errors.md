# Plan 2026-08-20-004 · 修复 #206：invite_only 工作台 createJoinRequest 返回空 errors

## 背景

对 `invite_only` 工作台调 `createJoinRequest` 返回 `{ result: null, errors: [] }`——DB 0 行（安全正确）但调用方无从得知被拒原因，web 端退化为硬编码英文 `createJoinRequest failed`。

根因（scout 2026-08-20 HEAD 取证）：`Cgc2046.Changes.ValidateWorkspaceJoinPolicy`（`backend/lib/cgc_2046/changes/validate_workspace_join_policy.ex:24-26` join_policy != :request 分支、`:28-30` 工作台不存在分支）向 changeset 注入**空 `Ash.Error.Forbidden.exception([])`**——无 message 无 code 的容器类。AshGraphql `unwrap_errors`（resolver.ex:2996-3008）递归拍平 Invalid/Forbidden 类的 `errors` 字段，空类 → `[]`。

对照：同 action 链上 `ValidateWorkspaceHasOwner` 用 `InvalidAttribute`（有 AshGraphql.Error protocol 实现）所以能正常显示——两处写法不对称正是本 bug 的成因。**open 分支同样静默**（validator 对 open/invite_only 一视同仁）。

## 决策

**BusinessError 模式**（i18n Phase 0 契约 + error_code_contract_test 命名规范的对齐首选）：

- code 命名 `join_request_invite_only` / `join_request_open`（`<resource>_<reason>` snake_case，契约正则 `^[a-z]+(_[a-z0-9]+)+$`）——**不用** issue 字面的裸 `invite_only`（不符合资源前缀语义）。
- open 分支一并覆盖（scout deletion test：该分支必须存在且需可读化，一次改动同根因双分支）。
- 工作台不存在分支（:28-30）转 `join_request_not_found`（同模式；暴露 workspace 存在性仅限已过 actor 认证的调用面，与现状 Forbidden 信息量差异可接受——GraphQL 面本来就能从 workspace 列表推断）。

拒绝 InvalidAttribute 直加（次选）：渲染 code 固定 `invalid_attribute`，不满足稳定业务 code 契约。

## 实施单元（backend + web，单 PR）

### U1 backend：`validate_workspace_join_policy.ex`

三分支的 `Ash.Changeset.add_error(Ash.Error.Forbidden.exception([]))` 全部替换为 `Cgc2046.Errors.BusinessError.exception(message: ..., code: ..., fields: [:workspace_id])`（复用 `backend/lib/cgc_2046/errors/business_error.ex:1-38` 的既有 AshGraphql.Error 实现）：

| 分支 | code | message（en 语义，zh 由前端 i18n 承载） |
|---|---|---|
| join_policy == :invite_only | `join_request_invite_only` | This workspace is invite-only |
| join_policy == :open | `join_request_open` | This workspace is open to join directly |
| workspace 不存在 | `join_request_not_found` | Workspace not found |

### U2 backend 测试

1. `backend/test/cgc_2046/accounts/join_request_test.exs:92-110`：open/invite_only 两处 `{:error, %Ash.Error.Forbidden{}}` 断言更新为 BusinessError code 断言。
2. GraphQL 层新增 invite_only 拒绝形态断言（放 `graphql_rbac_test.exs`，复用 :81-87 helper）：`errors[0].code == "join_request_invite_only"` 且 message 非空。
3. `backend/test/cgc_2046_web/error_code_contract_test.exs:133-184` 命名清单新增 `join_request_invite_only` / `join_request_open` / `join_request_not_found`。

### U3 web

1. `web/lib/requests.ts:78-92`：`createJoinRequest` 错误抛出改为带 code（error 对象携带 code，或抛含 code 的 message 拼接——按文件内既有 error 形态惯例选最小改动）。
2. `web/app/[locale]/join/page.tsx:166-169,345-357`：catch 后优先按 code 查 `t("errors.<code>")`（`t.has` 判存在），回退 `e.message`。
3. `web/messages/{en,zh-CN}.json` errors namespace（:15-19 附近）成对新增三 key（en 100% 覆盖门槛，`scripts/check-i18n-keys.mjs` 校验）：
   - `join_request_invite_only`：该工作台仅限邀请加入 / This workspace is invite-only
   - `join_request_open`：该工作台可直接加入，无需申请 / This workspace is open to join directly
   - `join_request_not_found`：工作台不存在 / Workspace not found

## 验收标准

1. `mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿。
2. `pnpm typecheck / lint / test / build` 全绿（web）。
3. GraphQL invite_only 拒绝响应含非空 message + code（新测试断言）。
4. web join 页对 invite_only 拒绝显示中文文案（i18n key 生效路径）。

## 非目标

- 小程序零改动（无 join 消费面，scout 已核实）。
- 不改 `Ash.Error.Forbidden` 基类的 protocol 缺失（AshGraphql 依赖层）。
- 不动 `graphql_schema.ex`（mutation 是 AshGraphql 自动生成，join_request.ex:324-325）。
- join 页不整体改用 payment-errors translator（本次最小面：`t.has` 查表）。

## 风险

| 风险 | 缓解 |
|---|---|
| join_request_test 既有断言破坏 | U2.1 同步更新为 code 断言 |
| en/zh key 漏配 | check-i18n-keys 门槛 + 成对提交纪律 |
| messages/{en,zh-CN}.json 与 #226 线同文件 | 不同 namespace（errors vs workspaceMcp），键不冲突；合并串行（后线 rebase），见并行终判 |
| code 契约清单漂移 | U2.3 显式入清单，防未来漏检 |

## 关联

- Issue #206（本 plan 关闭目标）
- Scout 报告：`agent://Scout206`（2026-08-20，HEAD 取证）
- 模式先例：`enrollment.ex:1064-1148`（BusinessError + domain_error_code）、`business_error.ex:1-38`
