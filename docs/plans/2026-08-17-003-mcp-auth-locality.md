# 架构深化候选 C：MCP 工具鉴权立场随工具走（Wrapper 清单下沉 + 派生门控）

> 日期：2026-08-17 · 来源：架构深化评审 2026-08-16 候选 C（`docs/reviews/architecture-review-2026-08-16.html`，git 2138b34；跟踪 issue #185）+ scout 只读取证（AuthLocalityScout，HEAD 884b30d 重定位 + anubis_mcp 2.0.0 库源码机制核查）· 状态：自治流水线批准（用户 2026-08-17 选定串行 C → E+G → D）
> 范围纪律：行为不变——12 工具门控语义逐工具等价（member-only / workspace_optional / membership_deferred 三形态）；仅改变「豁免声明」的物理位置（wrapper.ex 清单 → 工具模块自身）与消费方式（静态清单 → 组件注册派生）。

## 问题（HEAD 884b30d 坐实，评审行号已失效）

1. **清单在工具模块之外**（locality 破坏）：`wrapper.ex:24` `@workspace_optional`（confirm_operation/cancel_operation）+ `:35` `@membership_deferred`（save_step_output + plan001 新增三学员工具）共 6 个豁免工具。新写非成员可用工具必须知道去 wrapper.ex 改清单——plan001 U3 已实证该摩擦（一次 +3）。
2. **删除风险形态最差**：删清单条目无编译错误、无直接测试断言清单内容——学员静默 403（现有 e2e 是隐式护栏，靠 learning_flow 验收 2 恰好穿路径）。
3. plan001 已解决的部分（不再做）：三学员侧工具组合规则已单源 `LearnerAuthorization.authorize/3`。

## 方向判定（scout 库源码证据）

- **方向②（彻底单源到资源 policy）不采用**：save_step_output 会丢 member 的 StepRole 门禁（policy bypass 放行任意成员；step_key 是工具参数，进 policy 需 changeset context 穿线）+ 错误文案劣化；课程工具需新增 ResearchOutput/Course 学员 policy 并移除 `authorize?: false`——改动面大且违背 plan001「工具层判定」纪律。
- **方向①（立场随工具走）采用，载体修正**：评审提议的顶层 component opt `membership_gate:` 会被 `Anubis.Server.Component.__using__` **静默丢弃**（component.ex:32-180 只读已知 opts）；Anubis 原生自定义载体是 **`meta:` opt（map）**——生成 `meta/0` optional callback（tool.ex:169,222），经 `parse_components` 入 `%Tool{meta}`（server.ex:415-452），`Server.__components__(:tool)` 运行时可反射。
- **save_step_output 组合规则两份判定为不收**：工具层兜底（save_step_output.ex:79）与 policy bypass（workflow_run.ex:464-467）是分层必然（工具门 + 资源门，删任一份即行为回归），谓词已单源（StepAuthorization.enrolled_learner?/3），deletion test 不支持再抽。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | **载体 = `meta:` component opt**（Anubis 原生，零发明）：6 个豁免工具在 `use Anubis.Server.Component` 声明 `meta: %{workspace_id: :required \| :optional, membership: :member \| :deferred}`。confirm/cancel = `%{workspace_id: :optional}`（membership 隐含免检）；其余 4 = `%{membership: :deferred}`（workspace_id 隐含 :required）。`_meta` 经 tools/list 对 MCP 客户端可见——内容为低敏门控事实（本工具需要 workspace_id / 豁免成员门槛），无攻击面增益，接受 |
| D2 | **Wrapper 派生消费**：删除 `@workspace_optional`/`@membership_deferred` 与 `workspace_optional?/1`；经 `Cgc2046.Mcp.Server.__components__(:tool)` 构建 name→meta 映射并以 `:persistent_term` 缓存（规避 Wrapper→Server 编译依赖；模块加载序安全）；`check_workspace_id`（D12 必填校验）与 `check_membership` 的 cond 改读派生映射——**未声明 meta 的工具 = member-only + workspace_id 必填（fail-closed 默认）**，新工具漏声明不会静默放行 |
| D3 | **行为等价基线**：逐工具门控语义与现状一一对应（6 豁免 + 6 member-only）；现有 e2e 全部原样绿：learning_flow_test 验收 2（学员写进度全路径）、course_tools_test 场景 1/2/7、tools_test（D12 + 非成员 forbidden） |
| D4 | **一致性测试**（结构性消除删除风险）：新增测试断言派生门控集合恰为 6 个豁免工具（名单精确断言）+ member-only 工具不携带豁免 meta——新工具漏声明、豁免被误删均直接红 |
| D5 | **测试零改动**：既有测试文件零删改，只加 D4 新测试 |
| D6 | **文档**：CONTEXT.md 修订「MCP server」相关词条（工具鉴权立场 = 工具自身 meta 声明 + Wrapper 派生门控 + fail-closed 默认；删除原「例外清单」表述） |
| D7 | **不动**：save_step_output 兜底 + policy bypass（D-方向判定）、LearnerAuthorization、StepAuthorization、server.ex 组件注册结构（不加 opts，name 派生不变）、resources 目录、错误文案、审计链 |

## 改动清单

- **改**：`backend/lib/cgc_2046/mcp/wrapper.ex`（删两清单；派生映射 + persistent_term 缓存；两 check 改读）· 6 个工具模块（confirm_operation / cancel_operation / save_step_output / get_course_content / get_learning_records / save_learning_records 各 +meta opt）· `CONTEXT.md`
- **新增**：一致性测试（挂 `backend/test/cgc_2046/mcp/` 下，如 `wrapper_gate_test.exs`）
- **不动**：D7 全清单 · 数据库/配置/前端/SDL：无

## 实施顺序与验收

1. 6 工具 meta 声明 + Wrapper 派生改造 → 2. D4 一致性测试 → 3. CONTEXT.md → 4. 验收：`mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿；既有测试零改动；e2e 护栏（learning_flow 验收 2 / course_tools 1·2·7 / tools_test）绿
