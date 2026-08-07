# Slice C 整体实施计划（#34-#39）

> 关联：ADR-0002（workflow-first + Jido）、ADR-0003（pi 启发架构重构）、#85（重构方案）、`slice-c-workflow-definition-schema.md`（#34 schema）
> Slice：C（#34-#41 后端核心 #34-#39 + 展示 #40 + 验证 #41）
> 状态：草案，待审批（SOP §4）
> 基线日期：2026-08-06

---

## 1. 调研综合（5 份 scout 交叉印证）

### 1.1 技术底座定论（Jido 生态，hex 文档 + POC 双视角印证）

| 依赖 | 版本 | 状态 | 说明 |
|---|---|---|---|
| `jido` | ~> 2.3 (2.3.2) | 成熟（109k 下载） | 五件套：Agent/Action/Signal/Directive/Strategy |
| `jido_runic` | ~> 1.0 (1.0.0) | 已毕业（底层 runic 仍 alpha） | DAG 桥接：ActionNode/SignalMatch/SignalFact/Strategy |
| `ash_jido` | ~> 1.0 (1.0.0) | 可用（与 Ash 3.31 兼容） | Ash Resource action → Jido Action 编译期生成 |
| `runic` | 0.1.0-alpha.8 | alpha（jido_runic 锁定） | 底层 DAG 引擎 |

**已验证可行的架构模式（POC 11/12 PASS）**：
- DAG 编排：`Runic.Workflow` + `ActionNode` + `Workflow.add(node, to: [...])`
- Agent 执行：`Jido.Agent` + `Jido.Runic.Strategy` + `workflow_fn` 模板（每次构建新 struct = 天然快照）
- 实例化：`InstanceManager.get/3` keyed singleton（on-demand + 幂等复用 + hibernate/thaw）
- 多租户：`partition: workspace_id`（运行时隔离）+ Ash `attribute :workspace_id`（数据隔离），正交不冲突
- hibernate/thaw：`InstanceManager.stop/get` → `Jido.Persist.hibernate/thaw`，A1-A5 全 PASS
- 异步事件：`Jido.Signal.Bus` publish/subscribe + journal 重放 + 幂等
- ash_jido 桥接：Ash action 自动成 Jido Action，`actor`/`tenant` 从 GraphQL 上下文传入
- **SignalMatch 门控**：确认存在独立模块，人工步骤等 signal type → 匹配 → 放行

**主路径决策**：执行走 **Workflow 层 runic 原生 runner**（`Workflow.react/2`，靠图边状态驱动），**不走 Agent 策略层 join**——后者有 F1 死锁缺陷（`handle_apply_result` 把 `result=:waiting` 的 join 占位也算"已运行"，第二次 feed 被过滤→死锁）。

### 1.2 领域模型定论（ER 权威源）

权威源：`docs/01-定稿设计/领域模型定稿.md` §5.2 ER + §4.3 Step 四分类 + §8 审计映射。

| 资源 | 关键字段（ER） |
|---|---|
| WorkflowDefinition | id, name, type(6 枚举), version, input_schema(json), node_def(json), status(draft/published/archived), approval_timeout(int, 默认7天, F7) |
| WorkflowRun | id, definition_id, **definition_version**(绑定版本), status(pending/running/waiting/succeeded/failed/cancelled/expired), input_snapshot(json), facts(json), partition_id(=workspace_id), started_at, finished_at |
| Step | id, definition_id, type(auto/manual/gate/subworkflow), title, agent_id, sub_definition_id |
| StepRole | id, step_id, role_id |
| SignalLog | id, run_id, signal_type, payload, actor_id, received_at |

**hibernate/thaw（POC-2 G1 全 PASS）**：checkpoint 存 workflow state + `__strategy__`，thread 存 pointer `%{id, rev}`，生产 storage 用 Postgres/Redis（**不用 ETS**）。F2 deadline 唤醒待补集成测试。

**审计（ADR-0002 决策 7 + ADR-0003 原则 4）**：Thread journal = 引擎内部 append-only 写源（事件溯源）；Ash Notifier/PubSub = 产品层消费通道（按需写 ToolCallLog/AgentRun）。两者不冲突。

### 1.3 pi 可迁移原则（非代码）

| pi 原则 | slice C 落地 |
|---|---|
| 无状态循环 + 有状态壳 | `WorkflowEngine.run_step/2` 纯函数 + `Runner` GenServer 状态壳 |
| checkpoint 增量更新 | hibernate 传旧 summary，thaw 增量更新（summary + first_kept_step_id） |
| Step 执行三阶段 | `prepare_step` → `execute_step` → `finalize_step`，`before_step`/`after_step` hook |
| 非核心原语不内建 | 子 workflow 是 step type 一种；审计走事件订阅；审批走 prepare 钩子 |
| 会话树 parentId | **不需要**（DAG 路径确定），重跑用 `rerun_of_step_id` |

### 1.4 风险审查（7 项）

| # | 风险 | 严重度 | 阻塞 | 缓解 |
|---|---|---|---|---|
| R1 | 适配层设计缺失 | 中 | **是** | 本计划 §3 先定适配层接口 |
| R2 | Ash×Jido 租户对齐 | 低 | 否（POC 已实证） | workspace_id 同时传 Ash tenant + Jido partition |
| R3 | hibernate/thaw 存储 | 低 | 否（POC 已实证） | Postgres 自建 `Jido.Storage` 适配器；F2 deadline 补 |
| R4 | 并发串行化 | 中 | 否（需设计） | per-WorkflowRun 乐观锁（version 字段），不复用 advisory lock |
| R5 | 版本快照 | 中 | 否（已决策） | WorkflowRun 绑定 definition_version，已发布版本不可变 |
| R6 | 审计耦合 | 低 | 否 | Thread journal 写源 + 事件订阅消费 |
| R7 | 依赖许可 | 低 | 否 | jido 全 Apache-2.0，合规 |

---

## 2. 关键决策（已定）

| 决策 | 选择 | 理由 |
|---|---|---|
| Step 建模 | **独立 Ash Resource** | ER 图权威；StepRole 通过 step_id 直接关联，#38 授权查询高效；node_def 只存执行拓扑（顺序/依赖） |
| type 枚举 | **全 6 个** | 与领域模型定稿一致；slice C 先实现 research，其余预留 |
| 版本快照 | **WorkflowRun 绑定 definition_version** | 运行时按 version 回查不可变定义；已发布版本不可修改 |
| 引擎主路径 | **Workflow 层 runic runner** | 避 F1 死锁；`Workflow.react/2` 图边状态驱动 |
| checkpoint 存储 | **Postgres（自建 Jido.Storage 适配器）** | 不用 ETS；幂等键用 Postgres 唯一约束 |
| 串行化 | **per-WorkflowRun 乐观锁** | version 字段 + 条件更新，不复用 advisory lock |

---

## 3. 适配层设计（R1 阻塞项先行）

新建 `lib/cgc_2046/workflows/jido_adapter.ex`，包装 slice C 实际调用的 jido API，隔离 alpha 风险：

```elixir
defmodule Cgc2046.Workflows.JidoAdapter do
  @moduledoc """
  jido_runic / runic alpha 适配层（ADR-0002 锁版本 + 隔离）。
  所有 jido 内部 API 经此包装；升级或替换自研 DAG 只改本文件。
  """

  # 1. DAG 构建：Runic.Workflow + ActionNode
  def build_workflow(defn), do: ...        # 包装 Workflow.new/add
  # 2. 执行：Workflow 层 runner（避 F1 死锁）
  def react_until_satisfied(workflow, facts), do: ...  # 包装 Workflow.react/2
  # 3. 信号注入：人工步骤放行
  def feed_signal(workflow, signal), do: ...  # 包装 runic.feed_signal
  # 4. 持久化：hibernate/thaw
  def hibernate(run_id, partition), do: ...    # 包装 InstanceManager.stop → Persist.hibernate
  def thaw(run_id, partition), do: ...         # 包装 InstanceManager.get → Persist.thaw
  # 5. 信号总线
  def publish(signal_type, payload, partition), do: ...  # 包装 Signal.Bus.publish
  def subscribe(signal_pattern, fun, partition), do: ...
  # 6. 读路径：run facts（避免 runic Fact 内部结构泄露到产品层/#40）
  def list_run_facts(run_id, partition), do: ...
end
```

**适配层集成测试**：覆盖"多信号分批 feed"路径（F1 死锁回归防护）。

---

## 4. 分阶段实施

每个阶段：目标 → ADR-0003 纪律 → 接口契约 → 测试 → 不做。

### 阶段 1：#34 依赖接线 + WorkflowDefinition + Step + 生命周期/版本（阶段 0+1 合并）
**ADR-0003 纪律**：蓝图是数据；node_def 只存执行拓扑（顺序/依赖），Step 字段独立。
**接线（原阶段 0）**：
- 加 deps：`{:jido, "~> 2.3"}, {:jido_runic, "~> 1.0"}, {:ash_jido, "~> 1.0"}`
- `Application.start` 注册 InstanceManager + Pod supervisor（partition-safe）
- 建 `lib/cgc_2046/workflows/` 目录 + `Cgc2046.Api` domain 注册
- 跑 `mix cgc2046.check_licenses` 确认 jido 全 Apache-2.0
**实现**：
- `WorkflowDefinition` 资源：type 全 6 枚举、version、status、input_schema、node_def(执行拓扑)、approval_timeout
- `Step` 独立资源：definition_id、type(auto/manual/gate/subworkflow)、title、agent_id、sub_definition_id
- `WorkflowDefinition has_many :steps`
- actions：create(draft,v1) / publish / archive / new_version(v+1)
- **版本不可变**：published 版本不可修改；new_version 出 draft 修订
**接口契约**：WorkflowRun 后续按 definition_id+definition_version 回查。
**测试**（`workflow_definition_test.exs`）：draft→published→archived；new_version 出 v+1；published 不受新版本影响；租户隔离。
**不做**：不内建审批/MCP；不做依赖图解析（next 线性够）；不做 step handler 沙箱。

### 阶段 2：#35 WorkflowRun 状态机 + 引擎执行
**ADR-0003 纪律**：无状态引擎 + 有状态壳；审计走事件订阅；checkpoint 经回调。
**实现**：
- `WorkflowRun` 资源：definition_id、definition_version、status(pending/running/waiting/succeeded/failed/cancelled/expired)、input_snapshot、facts、partition_id、version(乐观锁)、started_at/finished_at
- `Cgc2046.Workflows.JidoAdapter`（§3）
- `Cgc2046.Workflows.Engine.run/2`（纯函数：构建 workflow → react_until_satisfied → 出 facts）
- 引擎主路径走 Workflow 层 runic runner
- telemetry 事件：`[:cgc, :workflow, :run, start|step|complete|fail]`
**接口契约**：WorkflowRun 创建时快照 input + 绑定 definition_version；执行引擎接收 run 快照 + actor + tenant。
**测试**（`workflow_run_test.exs`）：状态机流转；引擎执行自动步骤出 facts；租户隔离（partition）；乐观锁并发。
**不做**：引擎不内建审计（走 telemetry 事件订阅）；checkpoint 不进引擎核心；不做多 agent 编排。

### 阶段 3：#36 Step 四分类 + 顺序解锁
**ADR-0003 纪律**：Step 执行三阶段（prepare→execute→finalize）；子 workflow 是 step type 不是核心。
**实现**：
- `Cgc2046.Workflows.Engine.prepare_step/3`：校验 input_schema + 依赖的 prev step 完成
- `execute_step/3`：auto→JidoAdapter 调 Action；manual→进 waiting；gate→条件路由；sub_workflow→递归调 Engine
- `finalize_step/3`：规范化 facts、触发下游、telemetry
- 顺序解锁：Step.next 约束，prev 完成才 execute
**接口契约**：Step.type 四值；execute 返回 `{:ok, facts} | {:waiting, step_id} | {:error, _}`。
**测试**（`step_test.exs`）：四分类各跑通；顺序解锁（step1 未完成 step2 不执行）。
**不做**：不做依赖图解析；sub_workflow v1 可先 stub（#39 实现时细化）。

### 阶段 4：#37 人工步骤 waiting + 信号放行
**ADR-0003 纪律**：checkpoint 剥离为产品层服务；引擎只提供回调；增量更新。
**实现**：
- execute 到 manual step → run status=waiting → JidoAdapter.hibernate
- `Cgc2046.Workflows.SignalLog` 资源：记录收到的 signal
- 人工发 signal → JidoAdapter.feed_signal → SignalMatch 匹配 → 放行 → JidoAdapter.thaw → 继续
- checkpoint 服务（产品层，经 `transform_context` 回调）：存 summary + first_kept_step_id，增量更新
- **Postgres Jido.Storage 适配器**：checkpoint + thread journal 存 CGC Postgres（阶段 2 先用 ETS 跑通状态机，阶段 4 换 Postgres 适配器）
- deadline：`Directive.schedule` 唤醒 → expired/cancelled（F2）
**测试**（`human_step_test.exs`）：信号放行恢复；hibernate/thaw 正确；恢复期间信号不丢不重；deadline 到点 expired。
**不做**：checkpoint 不进引擎核心（产品层服务）；不做 ETS（用 Postgres）。

### 阶段 5：#38 StepRole 授权
**ADR-0003 纪律**：授权外置为 prepare 阶段钩子；声明式。
**实现**：
- `StepRole` 资源：step_id + role_id
- `Cgc2046.Workflows.Engine.prepare_step` 增加 before_step 钩子：actor 角色集 ∩ step 执行角色集 → 空则 `{:error, :unauthorized}`
- 复用 `MembershipContext.role_names/2` 取 actor 角色
- 自动/gate/sub_workflow 步骤由引擎执行不授权；manual 步骤授权信号发起人
**测试**（`step_role_test.exs`）：无权限执行被拒；多角色并集命中放行。
**不做**：不内建审批状态机（授权是 prepare 钩子）；平台管理员豁免待领域模型明确。

### 阶段 6：#39 教研 workflow 实例化（学习 workflow 推迟）
**实现**：
- WorkflowDefinition.type=research（已实现，阶段 1）
- Event/Course 创建 → `event.launched` signal → Engine 实例化 run
- sub_workflow step：type=:sub_workflow + sub_definition_id，Engine 递归执行
- **学习 workflow 推迟**：先跑通 research 端到端（#41），引擎与 Step 四分类的真实形态暴露后再写学习 workflow 设计（有真实引擎 API/Step 模式作参照，质量更高）。留到 slice E 或 slice C 收尾后单独推进。
**测试**（`teaching_learning_test.exs`）：教研定义复用多实例；子 workflow 嵌套。
**不做**：v1 不做 Workflow.merge/2 编译期模板组合（教研设计文档标记 v1 不引入）；不做学习 workflow（设计缺失，推迟）。

---

## 5. ADR-0003 不做清单（贯穿全程）

审计嵌入引擎核心、多 agent 编排进引擎、checkpoint 进引擎核心、step handler 沙箱、extension 版本管理、依赖图解析、全记录重写式 mutation、暴露原始 SQL、workflow 执行任意 shell、system prompt 含动态内容。

---

## 6. 测试接缝（Spec #22）

- backend：`cd backend && mix test`（Ash resource 行为：状态机/顺序解锁/信号放行/hibernate thaw/越权拒绝）
- web：`cd web && pnpm vitest`（产出展示页组件，#40）
- 手工端到端：#41 定义→发布→执行→waiting→放行→产出展示

---

## 7. 依赖与前置

- jido_runic 底层 runic alpha（适配层 §3 已隔离）
- F2 deadline 唤醒路径（阶段 4 集成测试补）
- 学习 workflow 设计推迟到 research 端到端跑通后

---

## 8. 已决策（SOP §4 审批通过 2026-08-06）

1. ✅ 阶段 0+1 合并（接线 + #34 一个 PR 闭环）
2. ✅ 适配层补 `list_run_facts/2` 读路径
3. ✅ 主路径走 Workflow 层 runic runner（避 F1 死锁）
4. ✅ Postgres Jido.Storage 适配器推迟到阶段 4（阶段 2 先 ETS 跑通状态机）
5. ✅ 学习 workflow 推迟到 research 端到端跑通后再设计
