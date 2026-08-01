# CGC 平台 Workflow 引擎 POC 验证报告

- 角色：Jido/Workflow架构研究员（worker_4cfa7aa2）
- 日期：2026-08-01
- 验证方式：Elixir 最小可运行原型（`poc/` 目录，mix 项目）
- 配套设计文档：`workflow-engine-ddd-design.md`（调研结论与定稿）

---

## 0. 验证目标与结论总览

围绕 CGC 平台 workflow 引擎的 5 个重点风险点进行最小原型验证：

| # | 验证项 | 结论 | 证据 |
|---|--------|------|------|
| 1 | jido_runic DAG 执行（报名 workflow 简化版） | ✅ PASS | `scripts/verify_1_dag.exs` |
| 2 | 人工步骤 SignalMatch 门控（waiting + 外部信号放行） | ✅ PASS（含 Agent 层缺陷根因确认与 saga 绕行） | `scripts/verify_2_gate.exs` / `scripts/verify_2_agent.exs` / `scripts/dbg_ran_filter.exs` |
| 3 | ash_jido 同步写（Enrollment 约束检查） | ✅ PASS | `scripts/verify_3_ash.exs` |
| 4 | 异步 Signal 订阅（enrollment.completed → 衍生动作） | ✅ PASS | `scripts/verify_4_signal.exs` |
| 5 | partition 多租户隔离 + Thread journal 审计溯源 | ✅ PASS | `scripts/verify_5_partition.exs` |

全部 5 项 PASS。`mix run scripts/verify_*.exs` 可独立复跑（脚本各自创建所需 ETS/进程）。

---

## 1. 验证环境（依赖锁定版本）

```
elixir       1.20.0
jido         2.3.2        (hex)
jido_action  2.3.1        (hex)
jido_signal  2.2.2        (hex)
jido_runic   1.0.0        (hex)
runic        ~> 0.1.0-alpha.4 (hex, alpha)
ash          3.31.0       (hex)
ash_jido     1.0.0        (hex)
```

> 注：Leader 最初指示锁 `jido ~> 0.1.x`，但生态已演进（jido 2.x / jido_runic 1.0 / ash_jido 1.0），
> POC 按当前实际版本验证；生产锁版本时以本报告版本为准。

---

## 2. 验证项 1：jido_runic DAG 执行（报名 workflow 简化版）— PASS

**场景**：报名 workflow 简化链 `validate → create → notify` 三节点线性 DAG。
用 `Jido.Runic.ActionNode` 包装 Jido Action，`Runic.Workflow` 构造 DAG，
`Workflow.react_until_satisfied/2` 执行。

**验证脚本**：`scripts/verify_1_dag.exs`

**结论**：
- DAG 三节点线性执行，最终产物 3 个（validate 产物 / Enrollment 记录 / notify 产物）；
- `CreateEnrollment` 同步写入 ETS（`:poc_enrollments`）立即可读；
- email 归一化（大小写）在 validate 步骤完成并传递到下游。

---

## 3. 验证项 2：人工步骤 SignalMatch 门控（waiting + 外部信号放行）— PASS

### 3.1 目标

报名 workflow 含人工审批步骤：报名信号触发 `validate → (等待审批) → create → notify`，
审批信号到达后才放行下游。验证"waiting + 外部信号放行"机制。

### 3.2 Workflow 层验证（PASS）

**场景**：`enrollment.submitted`（报名）→ validate → approval_bridge（join 等待审批信号）→
`enrollment.approved`（审批）→ join 放行 → create → notify。

**验证脚本**：`scripts/verify_2_gate.exs`（runic 内置 `react_until_satisfied` 双信号 feed）

**结论**：Workflow 层（runic 引擎内部循环）两信号分步 feed 正常：
- feed1 后 join 节点进入 waiting 占位（`Runnable.complete(runnable, :waiting, events)`）；
- feed2 后 join 满足条件，放行 create → notify，enrollments=1、thread_audit=1。

**关键机制（runic 三步模型）**：
1. `prepare`（build Runnable）→ 2. `execute`（返回 status=:completed, result=:waiting 或 completed/failed/skipped）→ 3. `apply_runnable`（fold events → maybe_finalize_coordination → emit_downstream_activations）。

### 3.3 Agent 层缺陷根因确认（关键发现，100% 双向证明）

**现象**：同样的 workflow 放进 Jido Agent（`JidoRunic.Strategy`，auto 模式）分批 feed 两个信号时，
feed1 后 join 被 dispatch 但未满足；feed2 时 join 虽已满足却被过滤，create/notify 永不执行 → 死锁。

**根因**（`jido_runic 1.0.0`，`strategy.ex` 的 `handle_apply_result`，auto 模式，约 363-440 行）：

```elixir
genuinely_new =
  new_runnables
  |> Enum.reject(&Map.has_key?(pending, &1.id))
  |> Enum.reject(fn r -> MapSet.member?(ran_nodes, r.node.hash) end)  # ← 缺陷
```

组合两条 runic 行为导致：
1. **Join.prepare 总是返回 `{:ok, runnable}`**（`invokable.ex` 约 1018-1069）：即使输入未凑齐
   （would_complete=false）也返回 runnable，`execute` 只是 `Runnable.complete(runnable, :waiting, events)` 占位；
   Coordinator.finalize 在 can_complete=false 时返回 `{wf, []}`（不改边 label）。
2. 因此 feed1 后 join.hash 已进入 `ran_nodes`（视为"已执行"）；
   feed2 时 join 实际已满足（:joined 边齐全），但被 `ran_nodes` 过滤 → 永不重新执行。

**双向证明**：
- `scripts/dbg_ran_filter.exs`（模拟 Agent 层 feed 流程，支持 ran_nodes 过滤开关）：
  - 开过滤 → feed2 后 join 不执行，create/notify 缺失（复现死锁）；
  - 关过滤 → feed2 完整执行 join → approval_gate → create → notify，enrollments=1 thread_audit=1。
- 同 workflow 在 Workflow 层（`react_until_satisfied`，无 ran_nodes 过滤）PASS。

**结论**：`jido_runic 1.0.0` 的 Agent 策略（auto 模式）不支持"同一 workflow 内用 join 等两个以上
异步信号"的人工门控模式；Workflow 层（runic 引擎直接驱动）可用。

### 3.4 Agent 层绕行实现（saga/事件驱动建模，PASS）

**绕行方案（Leader 已批准）**：Agent 层不再用单 workflow 内 join，改为 saga/事件驱动：
- 报名信号 → `validate_cond → validate → persist_pending`（写 ETS `:poc_pending` 后停住）；
- 审批信号 → `approval_cond → approval_bridge → approval_gate`（读回 pending 合并审批事实）→ `create → notify`；
- 两个信号各走独立分支，Agent 层可正确分批 feed。

**实现**：`poc/lib/poc/enrollment_workflow_saga.ex`（Poc.EnrollmentWorkflowSaga + Poc.EnrollmentSagaAgent）
**验证**：`scripts/verify_2_agent.exs` 两阶段 PASS：
- feed1 后：ran_nodes=[validate, persist_pending]，pending=1，enrollments=0（卡在审批）✅
- feed2 后：ran_nodes=[validate, persist_pending, approval_bridge, approval_gate, create, notify]，enrollments=1 thread_audit=1 ✅

### 3.5 对 CGC 建模建议（重要）

1. **Agent 层避免"单 workflow 内 join 等两个以上异步信号"**：人工门控如存在两个独立外部信号，
   用 saga/事件驱动（分 workflow 或子 workflow + 持久化 pending）建模，而不是单 DAG join；
2. **Workflow 层（runic 直接驱动）可保留 join 模式**：适合在进程内一次 feed 多个事实的场景；
   长期主路径建议以 Workflow 层为主（未来主路径依据），Agent 层用于需要 Agent 生命周期/策略的编排；
3. 生产接入时应在适配层加**集成测试**覆盖"多信号分批 feed"路径，防止升级 runic 后回归；
4. 建议给 jido_runic 提 issue：`genuinely_new` 的 ran_nodes 过滤对 join/waiting 类节点应允许重新评估
   （例如 join 未 complete 时不应进入 ran_nodes）。

---

## 4. 验证项 3：ash_jido 同步写（Enrollment 约束检查）— PASS

**场景**：用 Ash Resource（ETS data layer）+ AshJido 把 `Enrollment.create/read` 生成 Jido Action，
验证：同步写、立即可读、约束检查（邮箱格式 / 必填 / email 唯一）。

**实现**：`poc/lib/poc/enrollment_ash.ex`
- `Poc.Accounts`（Ash.Domain，`validate_config_inclusion?: false`，注册 Poc.Enrollment）
- `Poc.Enrollment`（Ash.Resource，data_layer: Ash.DataLayer.Ets，extensions: [AshJido]）
  - 必填：name/email/city（`allow_nil?: false`）；email 格式 `constraints: [match: ~r/.../]`；
    status 默认 "enrolled"
  - identity：`identity :unique_email, [:email], pre_check_with: Ash.DataLayer.Ets`
  - jido DSL：`action :create`、`action :read` → 生成 `Poc.Enrollment.Jido.Create / Read`

**验证脚本**：`scripts/verify_3_ash.exs` 全部 PASS：
- ✅ 模块生成且导出 run/2（Create/Read）
- ✅ 同步写成功：返回完整字段（id/name/status/email/city/event_id/approved_by）
- ✅ 同步可见：create 后立即 Read 可查（1 条）
- ✅ 约束生效：非法 email 拒绝 / 缺 city 拒绝 / 重复 email 拒绝（"has already been taken" unique 语义）
- ✅ 库中共 1 条

**踩坑记录**（对生产实现有直接参考价值）：
1. `validate format(:email, ~r/.../)` 编译失败（undefined function format/3）→ 改用 attribute
   `constraints: [match: ...]`；
2. 生成的 action 输出只有 id → **Ash 3.31 attribute 默认 `public?: false`**（仅 primary key 默认 public），
   业务字段需显式 `public?: true` 才进入 Mapper 输出；
3. Ets data layer 的 identity 必须 `pre_check_with: Ash.DataLayer.Ets`，否则 DslError
   （data layer 不支持 native identity 检查）；
4. AshJido Read action 的 filter 用简单相等 `%{email: "..."}` 即可；返回格式为
   `{:ok, %{result: [records]}}`（list 被 ensure_map_output 包一层）。

---

## 5. 验证项 4：异步 Signal 订阅（enrollment.completed → 衍生动作）— PASS

**场景**：主流程报名完成后发布 `enrollment.completed` 信号；独立订阅 Agent 通过 Signal Bus
异步收到信号并触发衍生动作（创建 follow-up / 确认邮件记录），主流程无需等待。

**实现**：
- `poc/lib/poc/enrollment_followup.ex`
  - `Poc.Actions.CreateFollowUp`（衍生动作）：写入 `:poc_followups`
  - `Poc.Agents.EnrollmentFollowUpAgent`（`use Jido.Agent`，`signal_routes: [{"enrollment.completed", CreateFollowUp}]`）
- Bus：`Jido.Signal.Bus.start_link(name: :poc_bus)`；订阅：
  `Bus.subscribe(:poc_bus, "enrollment.completed", dispatch: {:pid, target: server_pid, delivery_mode: :async})`
  （PidAdapter 异步投递 `{:signal, signal}`，AgentServer 的 `handle_info({:signal, ...})` 经
  signal_routes 路由到动作）

**验证脚本**：`scripts/verify_4_signal.exs` PASS：
- ✅ Signal Bus 启动、订阅 Agent 启动、订阅成功
- ✅ 主流程创建 Enrollment → publish enrollment.completed（fire-and-forget）
- ✅ 订阅者异步收到信号，CreateFollowUp 执行，`:poc_followups` 1 条
  （follow_up_id / enrollment_id / kind=confirmation_email）
- ✅ 路由表已编译：`signal_routes()` 返回 `[{"enrollment.completed", Poc.Actions.CreateFollowUp}]`

**说明**：`signal_types()` 只返回 plugin 展开路由（本 POC 无 plugin 路由故为空）；
agent 级 `signal_routes/0` 才是路由表（已验证）。启动 AgentServer 前需
`Jido.start_link(name: Jido)` 建立默认实例（AgentServer 默认 registry 为 `Jido.Registry`）。

---

## 6. 验证项 5：partition 多租户隔离 + Thread journal 审计溯源 — PASS

**场景**：同一 Jido 实例下两个租户（:tenant_a / :tenant_b）各有一个**同名** Agent
（id="enrollment-1"），partition 隔离；每个 Agent 用 Direct strategy（`thread?: true`）
自动把每次信号处理写入 Thread journal，验证审计可溯源。

**实现**：`poc/lib/poc/enrollment_partition.ex`
- `Poc.Agents.PartitionEnrollmentAgent`（`strategy: {Jido.Agent.Strategy.Direct, thread?: true}`，
  `signal_routes: [{"enrollment.submitted", Poc.Actions.CreateEnrollment}]`）

**验证脚本**：`scripts/verify_5_partition.exs` PASS：
- ✅ partition key 隔离：`Jido.partition_key("enrollment-1", :tenant_a) != :tenant_b != nil`
  （`{:partition, :tenant_a, "enrollment-1"}` 等）
- ✅ 同名 Agent 在两个 partition 下均启动成功（注册表 key 不冲突），且是不同进程
- ✅ 按 partition 定位：`AgentServer.whereis(Jido.Registry, "enrollment-1", partition: :tenant_a/b)`
- ✅ 数据隔离：tenant_a / tenant_b 各 1 条记录，email 互不串扰
- ✅ Thread journal 审计溯源：每个 Agent 的 thread 记录 `instruction_start/instruction_end`
  成对条目（action、param_keys、instruction_id），起止配对完整
- ✅ journal 隔离：tenant_a 的 journal 不含 tenant_b 数据，反之亦然

**审计链形态示例**（tenant_a）：
```
[entry_...] kind=instruction_start payload=%{action: Poc.Actions.CreateEnrollment,
  param_keys: [:name, :email, :city, :event_id, :tenant], instruction_id: "..."}
[entry_...] kind=instruction_end   payload=%{status: :ok, action: ...}
```

**结论**：Workspace=partition 的建模成立；Thread（append-only journal）可直接作为审计 context
数据源，与 DDD 设计草案 C 一致。

---

## 7. 对 DDD 设计的修正/细化建议（基于 POC 实证）

1. **人工步骤模式（修正草案 A 2.1）**：
   - 原定"workflow 内部等待（Human-in-the-loop）为主"成立，但**必须限定在 Workflow 层
     （runic 直接驱动）或 saga 分支模式**；Agent 策略（auto）下单 DAG join 等两个异步信号
     会死锁（见 3.3）。
   - 建议 v1 主路径：**Workflow 层 + 人工步骤信号门控**；Agent 层用于需要 Agent 生命周期/策略
     的编排，人工等待用 saga（持久化 pending）。
2. **同步/异步决策（草案 B，已验证）**：核心写走 ash_jido 同步 Action（强一致 + 约束检查，验证项 3），
   衍生副作用走 Signal Bus 异步订阅（验证项 4）。验证通过，按 8:2 落地。
3. **多租户与审计（草案 C，已验证）**：partition 隔离 + Thread journal 审计成立（验证项 5）。
   Thread 建议同时记录**业务事件**（如 enrollment.completed 发出）+ **指令执行**（instruction_start/end），
   形成完整溯源链。
4. **幂等与重试（补充）**：异步订阅路径已验证可行，生产需为每个衍生动作定义幂等键
   （如 enrollment_id + 动作类型），Signal Bus 支持 journal/replay（ETS/Mnesia adapter），
   可在 v1 用 Bus journal 做重放兜底。
5. **runic alpha 风险（重申）**：`runic 0.1.0-alpha.4` 仍在实验期；POC 已暴露 1 个 Agent 层缺陷
   （join 跨信号死锁），生产必须锁版本 + 适配层 + 集成测试。

---

## 8. 开放问题引擎侧结论（基于 POC 实证）

> 对应《docs/01-定稿设计/报名workflow详细设计.md》§7 的 **15 项开放问题**（v1.1 已从 12 项扩展，新增 #13/#14/#15）。
> 本报告从**引擎能力**视角给三分类：**✅ 已验证**（POC 实证）/ **🔬 需 POC-2**（需专门验证）/ **📐 需改设计或建模决策**（引擎不构成阻碍或需调整方案）；
> 与设计文档 §7 的建模视角结论（✅定稿 / 🟡待 POC-2 / 🔶待 grill）互补对照，列于"设计文档 §7"列。

| # | 开放问题 | 引擎侧结论 | 分类 | 设计文档 §7 |
|---|---------|-----------|------|------------|
| 1 | **名额并发控制** | 同步写 + 约束兜底的机制已验证（验证项 3：Ash 约束/identity 生效）；原子扣减用 Ash update action + filter（`count < capacity`）实现"条件扣减"，锁粒度取决于 data layer（POC 用 ETS 为进程内原子，生产 Postgres 需行锁/唯一索引兜底）。**并发压测未做**，可放 v1 联调期（§9 G3 可选），不必单列 POC-2。 | 🔬 部分已验证 + 实现期压测 | ✅ 定稿（事务内原子扣减） |
| 2 | **幂等实现** | 业务唯一索引兜底已验证（email 重复 → "has already been taken"，验证项 3）；request_id 存 WorkflowRun.input_snapshot 的机制**未验证**；Signal 层 idempotency_key 重放幂等需 POC-2 G2（B3）。 | 🔬 部分已验证 + 需 POC-2（Signal 幂等） | ✅ 定稿（三层幂等键） |
| 3 | **request 策略审批入口** | 引擎上审批 = 向 workflow 发 approval 信号触发 SignalMatch 门控，机制已验证（验证项 2，saga 版）；入口形态（网站审批页 vs MCP）属产品决策，引擎无阻碍。 | ✅ 引擎无阻碍（归口：产品/建模） | 🔶 待 grill |
| 4 | **invite_only 凭据来源** | 引擎侧仅是校验步骤（Action schema 校验邀请凭据），与 validate 步骤同类，机制已验证（验证项 1/2）；凭据数据模型归口领域建模。 | ✅ 引擎无阻碍（归口：建模） | 🔶 待 grill |
| 5 | **报名截止驱动 vs 定时器** | SignalMatch 门控 + 提交时 Action 校验 deadline：机制已验证（门控与校验均实证）；但 **hibernate 期间 deadline 到点如何唤醒并 cancel 未验证**（需 Schedule Directive 或事件触发），列入 POC-2 G1。 | 🔬 部分已验证 + 需 POC-2（唤醒触发） | 🟡 待 POC-2 |
| 6 | **draft 状态是否需要** | 不涉及引擎能力；v1 砍掉 draft 从 submitted 起，引擎无阻碍。 | ✅ 不涉及引擎（归口：产品） | ✅ 定稿 |
| 7 | **Enrollment 唯一索引形态** | Ash identity 复合唯一约束机制已验证（验证项 3 用 email 单列；`(event_id,user_id)` 复合为 Ash 标准能力）；多态列 vs 双 FK 属数据建模决策，Ash 均支持。 | ✅ 机制已验证（形态归口：建模） | ✅ 定稿（双 FK） |
| 8 | **run 粒度** | 引擎上无阻碍：事件驱动 + 多 Agent/partition 已验证（验证项 4/5）；批量/团队报名 = 多次 cast 或循环，v1"一个报名 = 一个 run"可行。 | ✅ 引擎可行（v1 决策归口：建模） | ✅ 定稿 |
| 9 | **hibernate 恢复正确性** | **核心未验证**：Checkpoint 存 input_snapshot+状态、waiting 恢复、先信号后 checkpoint 的竞态，均需 POC-2 G1 专门验证。 | 🔬 需 POC-2（最高优先） | 🟡 待 POC-2 |
| 10 | **S7 失败留痕** | Action 返回错误 → workflow/run failed 机制已验证（验证项 3 约束拒绝路径、runic failed 语义）；建模已定稿用 Thread journal 留痕、不落失败记录（验证项 5 journal 可承载），引擎无阻碍。 | ✅ 机制已验证（留痕策略归口：建模） | ✅ 定稿（journal 留痕） |
| 11 | **Visitor 注册与报名的原子性** | 跨 context（J-Visitor 注册 vs Enrollment 报名）不建议分布式事务；跨 context 协作走 Signal/异步已验证（验证项 4）；设计文档已按 **"分步 + 幂等重试"** 定稿（先注册后报名，报名失败提示重试，request_id 幂等），与本报告建议一致。 | 📐 已按建议改定稿（分步幂等） | ✅ 定稿 |
| 12 | **报名展示页数据来源** | Enrollment+WorkflowRun 双向查询：Ash Read 同步查询已验证（验证项 3）；按 run 还是 user+event 查、load relationships 均为接口设计，引擎支持。 | ✅ 机制已验证（接口归口：建模/前端） | ✅ 定稿 |
| 13 | **Agent 层 join 死锁** | **POC 已实证并绕行**：根因 = jido_runic 1.0 Agent 策略 ran_nodes 过滤（§3.3）；建模已按 saga 两段式定稿（§3.4），Workflow 层保留 join 模式，适配层加"多信号分批 feed"集成测试。 | ✅ 已验证（含绕行方案） | ✅ 定稿（saga） |
| 14 | **Bus journal 重放** | 异步订阅机制已验证（验证项 4）；journal/replay（ETS/Mnesia adapter）**未实测**，列入 POC-2 G2；v1 先用幂等键保证不重复副作用（B3 断言覆盖）。 | 🔬 需 POC-2（G2） | 🟡 待 POC-2 |
| 15 | **runic alpha 风险** | 版本锁定 + 适配层 + 集成测试策略成立（§3.5/§11）；POC 已暴露 1 个 Agent 层缺陷佐证风险真实存在。 | ✅ 已验证（风险确认） | ✅ 定稿（锁版本） |

**汇总**：15 项中引擎机制已验证/无阻碍 10 项（3/4/6/7/8/10/11/12/13/15）、部分验证需补充 2 项（1/2）、需 POC-2 3 项（5/9/14，其中 9 最高优先）、纯业务待 grill 2 项（3/4）。引擎选型（jido 2.3 + jido_runic 1.0 + ash_jido 1.0）对报名 workflow 主路径**无硬性阻碍**；与设计文档 §7 结论（✅10 / 🟡3 / 🔶2）完全一致，无冲突。

---

## 9. POC-2 范围建议（waiting 持久化 + Signal 可靠性）

> 供用户决定是否继续投入。验证目标、关键断言、建议实现方式、预估工作量（单人天，含环境与踩坑缓冲）。

### G1：waiting 持久化 + hibernate/thaw 恢复正确性（最高优先，对应开放问题 5/9）

- **验证目标**：人工审批 waiting 挂起期间 Agent 进程 hibernate/重启，thaw 后 workflow 状态完整恢复，后续审批信号正确放行继续；恢复期间到达的信号不丢失、不重复执行。
- **关键断言**：
  - A1：waiting 挂起后 hibernate（进程被回收），checkpoint 已持久化 workflow 状态 + input_snapshot；
  - A2：重启（同 id + partition 重新 start_link）后 thaw 恢复，waiting 节点仍处于 pending、线程 journal 完整；
  - A3：恢复后 feed 审批信号 → approval_gate 放行 → create/notify 完成，enrollments=1；
  - A4：恢复期间到达的审批信号不丢失（挂起/重放），且不重复执行（幂等）；
  - A5：恢复后再次 hibernate → 再次放行，循环 2 次仍正确。
- **建议实现方式**：
  1. 首选查证 `jido 2.3.2` 的 InstanceManager/Checkpoint Storage（ETS/文件）hibernate/thaw API，用 Direct strategy + thread journal（验证项 5 已证明 journal 完整）做恢复源；
  2. 若无现成 hibernate：用"杀进程 + 同 id/partition 重启"模拟崩溃恢复，从 Thread journal（已验证 append-only）重放重建 state；
  3. 挂起信号用 Signal Bus 的 ETS/Mnesia adapter 持久订阅（见 G2）或启动时 journal 补投；
  4. deadline 触发：验证 Schedule Directive 或"恢复时检查 deadline → 超时则 Emit cancel"路径（覆盖开放问题 5）。
- **预估工作量**：**1.5 ~ 2 天**。

### G2：Bus journal 重放（Signal 可靠性 + 幂等，对应开放问题 2/9）

- **验证目标**：订阅者离线期间发布的信号进入 journal；订阅者重启后重放补齐且结果与在线一致；重复投递（同 idempotency_key）不产生重复副作用。
- **关键断言**：
  - B1：订阅者离线时 publish 的信号进入 Bus journal（ETS/Mnesia adapter 持久化）；
  - B2：订阅者重启后收到 journal 重放信号，CreateFollowUp 执行，`:poc_followups` 条数 = 离线期间信号数；
  - B3：同 idempotency_key 重复投递 → 只执行一次（衍生动作幂等键生效，无重复 follow-up）。
- **建议实现方式**：
  1. 查证 `jido_signal 2.2.2` Bus 是否支持 ETS/Mnesia adapter 持久订阅 + 重放/水位 API；
  2. 若 Bus 无原生重放：用 Thread journal（已验证）记录"已消费水位"，重放 = 读 journal 找未处理信号再投递；
  3. 幂等键：衍生动作 schema 加 `idempotency_key` 必填，ETS 唯一索引兜底（复用验证项 3 已验证的唯一约束机制）。
- **预估工作量**：**1 ~ 1.5 天**。

### G3（可选加分）：名额并发压测（对应开放问题 1）

- **验证目标**：同 event 并发 N 报名不超卖。
- **关键断言**：capacity=10、并发 20 个 create_enrollment → 恰好 10 成功、10 被名额/唯一约束拒绝，无超卖。
- **建议实现方式**：Ash update action + filter（`count < capacity` 原子条件扣减）+ `Task.async_stream` 并发轰炸；ETS 版验证逻辑，Postgres 行锁留到生产环境压测。
- **预估工作量**：**0.5 天**。

### 投入决策建议

- **必做**：G1（hibernate 恢复是 waiting 人工步骤可靠性的地基）+ G2（异步副作用可靠性）。
- **可选**：G3 可在 v1 联调阶段用真实数据层压测，不必单独投入。
- **合计预估**：G1+G2 ≈ **2.5 ~ 3.5 人天**；加 G3 ≈ 3 ~ 4 人天。
- **退出标准**：G1 A1-A5、G2 B1-B3 全 PASS → 人工审批门控与异步副作用可进入 v1 生产设计；任一 FAIL → 按"需改设计"回退（如 waiting 改为 saga 持久化 pending + 显式恢复任务，不依赖引擎 hibernate）。

---

## 9.6 POC-2 验证结果（G1 waiting 持久化 + G2 Bus journal 重放）— 全 PASS ✅

> 按 §9 方案执行（实际投入约 1.5 人天，低于预估 2.5~3.5 人天）。脚本可复跑：`mix run scripts/verify_6_g1_hibernate.exs` / `mix run scripts/verify_7_g2_journal.exs`。

### G1：waiting 持久化 hibernate/thaw 恢复 — PASS ✅（A1-A5 全过）

**实现方式**（首选路径，jido 2.3.2 原生支持，未走"杀进程模拟"兜底）：
- `Jido.Agent.InstanceManager`（keyed 单例 registry + storage 备份）：`start_link(name:, agent:, storage: {Jido.Storage.ETS, table: :poc_checkpoints})`；
- `InstanceManager.get(:poc_mgr, key)` → lookup → maybe_thaw（`Jido.Persist.thaw`）→ 无则启动新实例；
- `InstanceManager.stop(:poc_mgr, key)` → `GenServer.stop(:shutdown)` → clean shutdown → `Lifecycle.Keyed.terminate` 自动调 `Persist.hibernate`；
- 恢复源 = checkpoint（含 workflow state + `:__strategy__`）+ thread journal（`Jido.Storage` 三表：`#{base}_checkpoints` / `#{base}_threads` / `#{base}_thread_meta`）。

| 断言 | 验证内容 | 结果 | 证据 |
|---|---|---|---|
| A1a | waiting 挂起后 hibernate：checkpoint 持久化 workflow 状态，thread 不内联（只存 pointer），workflow 可恢复 | ✅ | checkpoint 存在=true、state 含 `:__strategy__`=true、无内联 `:__thread__`=true、workflow 可恢复=true |
| A1b | hibernate 时 thread journal flushed 到 storage | ✅ | hibernate 后 threads 表 2 行，journal rev=2 start=1 end=1 |
| A2a | thaw 后 workflow 状态完整恢复：status/ran_nodes/pending 保留 | ✅ | thaw 后 status=success、components≥6、ran_nodes≥2、pending 保留 |
| A2b | thaw 后 thread journal 完整（rev 匹配、起止配对） | ✅ | thaw 后 rev=2、start=1=end（无悬挂） |
| A3 | 恢复后 feed 审批信号 → 放行 → create/notify 完成 | ✅ | 审批放行后 enrollments=1、thread_audit=1 |
| A4 | 恢复期间到达的审批信号不丢失、不重复执行 | ✅ | 挂起队列信号 thaw 后投递 → enrollments=1（不丢不重） |
| A5 | 循环 2 周期（hibernate→thaw→放行）仍正确 | ✅ | enrollment-1/2 两周期，清 pending 后 enrollments=2 |

**关键 API 实证**：`Jido.Persist.hibernate/thaw`（不变量：hibernate 时从 state 删 `:__thread__` 只存 `%{id, rev}`；thaw 时 rehydrate + 校验 rev，不匹配报 `:thread_mismatch`）；ETS storage 表名为 `:"#{base}_checkpoints"` / `:"#{base}_threads"` / `:"#{base}_thread_meta"`（非三元组 tuple）。

### G2：Bus journal 重放 + 幂等 — PASS ✅（B1-B3 全过）

**实现方式**：`jido_signal 2.2.2` 原生支持：
- `Bus.start_link(name:, journal_adapter: Jido.Signal.Journal.Adapters.ETS)`（ETS ephemeral 供 dev/test；File/Redis/Mnesia 供生产）；
- 无订阅者 publish → journal 记录；`Bus.replay(bus, path, start_timestamp)` 按时间过滤取回；
- persistent 订阅（`persistent?: true, start_from: :origin|:current`）维护 checkpoint/ack；`Bus.ack` 水位推进。

| 断言 | 验证内容 | 结果 | 证据 |
|---|---|---|---|
| B1 | 无订阅者时 publish 的信号进入 journal，可 replay 取回 | ✅ | publish 返回 2 条 recorded，replay 取回 2 条 |
| B2 | 订阅者离线期间 publish → 重启 → journal 重放补齐，结果与在线一致 | ✅ | 在线 1 条 → 停 agent → 离线 publish 2 条 → 重启 → replay 重放 2 条 → followups=3（在线已处理不重复） |
| B3 | 同 idempotency_key 重复投递 → 只执行一次 | ✅ | 第一次投递 followups 4，重复投递仍 4（insert_new=false，skipped） |

**关键发现（幂等表 owner 陷阱）**：`CreateFollowUp` 幂等键表若由 **action 执行进程** 创建，`run` 结束进程退出后 **ETS named table 随 owner 进程销毁**，下次投递重建空表 → 幂等失效（B3 一度 FAIL）。修复：幂等键表必须由长生命周期进程（supervisor / 脚本主进程 / 持久存储）持有 owner。**生产建议：幂等键表用 Postgres 唯一约束或 Redis，不要用 action 进程自建的 ETS。**

### POC-2 退出标准判定

- 退出标准「G1 A1-A5、G2 B1-B3 全 PASS → 人工审批门控与异步副作用可进入 v1 生产设计」：**已满足，判定进入 v1** ✅。
- 无需回退方案（saga 持久化 pending 为备选，保留在 v1 设计文档中作为兜底）。

---

## 9.7 教研 workflow 引擎侧查证（D-A2 定义一次、多 Event/Course 实例化复用）— PASS ✅

> 用户选 B 方向后新增：报名 workflow 未覆盖的新需求——WorkflowDefinition 定义一次、
> 被多个 Event/Course 实例化复用（教研 workflow：大纲设计 / 招募物料 / 答疑需按
> Event/Course 传参并行跑）。基于 jido 2.3.2 + jido_runic 2.2.2 源码调研 + POC 实证
> （`verify_8_d_a2.exs`，D-A2a~D-A2d 全 PASS）。

### D-A2a 定义-实例化模型：**原生支持，零额外机制** ✅

- jido 中「定义」= **Agent module（含 strategy）**；`use Jido.Agent, strategy: {Jido.Runic.Strategy, workflow_fn: &Mod.build/0}` 即定义一个 workflow 模板。`build/0` 每次调用返回全新的 `Runic.Workflow` 不可变 struct（同模板同名同结构，但不携带运行期状态）。
- **InstanceManager 天然支持定义复用**：`InstanceManager.get(mgr, key)` 是 keyed singleton——每个 key（如 `"course_1"` / `"course_2"`）启动一个独立 AgentServer 实例；每个实例 init 时调用 `workflow_fn.()` 构建自己的 workflow。**一个定义 → N 个 run，零引擎改动**。
- 幂等复用：同一 key 重复 `get` 返回同一实例（不重复建 workflow）。实例终止后再次 `get` 会从模板重新构建全新 run（从头开始）。
- POC 实证：`course_1`/`course_2` 两实例 pid 不同、workflow 同模板（`wf1 == wf2` 且 name 均 `:research_workflow`，证明定义复用）、初始均 `:idle` 互不干扰。

### D-A2b 模板参数化：**无占位符/变量替换，靠运行时输入注入** ✅

- **引擎没有**内建占位符/模板变量替换机制（grep runic/jido_runic 无 template/placeholder/interpolation；仅 `Workflow.merge/2` 支持运行时组合 workflow 片段，属编译期模板组合，非运行期参数替换）。
- **参数化路径（已验证）**：run input 作为 signal data 传入 → `SignalFact.from_signal` 转 Runic Fact（`value = signal.data`）→ `ActionNode` 执行时**把 fact value merge 进 node params** → Jido Action `run(params, context)` 从 params 读取 `course_id`/`event_id` 等。
- POC 实证：`course_1` 收到 `%{course_id: "course_1", event_id: "evt_101", title: "公文写作训练营"}`、`course_2` 收到 `%{course_id: "course_2", event_id: "evt_202", title: "AI 赋能教研"}`，同一定义下两条链各自按输入生成定向物料文案（`【course_1】招生开启…` / `【course_2】招生开启…`）。
- **设计影响**：教研 workflow 的「大纲设计/招募物料/答疑」Action 直接声明 `course_id`/`event_id` 为必填 schema 字段，Event/Course 上下文作为 run input 注入即可，**无需**为每个 Event 复制 Definition。

### D-A2c 实例化粒度与隔离：**按实例（进程级）隔离成立** ✅

- 隔离边界 = **AgentServer 进程 + 其 strategy state**：每个实例独立持有 workflow、status、ran_nodes、pending；Thread journal 存在于各实例 agent state（按实例独立，verify_5 已证 partition 场景）。
- **运行期状态互不污染（POC 实证）**：feed `course_1` 后其 status=`:success`，而 `course_2` 仍 `:idle`（未 feed 的实例不受影响）；两者 ran_nodes 各自记录。
- **产出落点按实例隔离**：业务 Action 以 `course_id` 为 key 写 ETS（outline/materials/qna 各 2 条，course_1/course_2 各一，qna thread metadata 各带自己的 course_id）。生产落点同理：Action 把 `course_id` 写进业务表行即可，无需引擎层隔离。
- **partition 的关系**：partition 是更粗的租户级隔离维度（registry key = `{partition, key}`，verify_5 已证）；实例级隔离用 key 即可，partition 用于租户/环境隔离，二者可叠加。

### D-A2d 生命周期：**引擎原生支持，应用层一个 signal 订阅即可** ✅

- InstanceManager 本身就是 on-demand 生命周期管理：**`event.launched` 信号触发实例化 = 应用层订阅该信号后调 `InstanceManager.get(mgr, "course_#{id}")`**，无需引擎额外机制。
- 生命周期闭环：Event 开启 → `get` 实例化（幂等，重复事件不重建）；运行中 idle 超时可 hibernate（storage 配置，G1 已验证 checkpoint/thaw 正确）；Event 结束 → `InstanceManager.stop` 释放实例（POC 实证 stop 后进程终止、再次 get 重新实例化）。
- **设计影响**：发布前建好模板（= 注册 Agent module / workflow_fn），Event 开启时实例化（= get + feed 参数化输入），Event 结束时回收（= stop / idle timeout）——三段生命周期全部落在现有 API 上。

### 结论与对设计的影响

| 查证项 | 结论 | 对教研 workflow 设计的影响 |
|---|---|---|
| 定义-实例化 | 原生支持（Agent 定义 + InstanceManager keyed singleton） | 领域模型直接映射：`WorkflowDefinition` ↔ Agent module（含 workflow_fn 模板）；`WorkflowRun` ↔ InstanceManager key（event_id/course_id） |
| 参数化 | 无占位符替换；signal data → fact → ActionNode params 注入 | Action schema 声明 course_id/event_id 必填；运行期 input 注入，无需复制 Definition |
| 隔离 | 实例级进程隔离 + 产出按 key 落点 | 多 Event 并行跑天然成立；业务表按 course_id 隔离产出 |
| 生命周期 | on-demand get / idle hibernate / stop | event.launched 订阅 → get；event 结束 → stop；无需引擎扩展 |
| 替代方案 | **不需要** | 若未来需要"定义动态组装"，用 `Workflow.merge/2` 组合片段（编译期模板组合），成本低 |

- **退出标准判定**：D-A2a~D-A2d 全 PASS → **定义一次、多 Event/Course 实例化复用可进入 v1 生产设计** ✅，无需复制 Definition / 模板脚本生成等替代方案。
- 产出文件：`poc/scripts/verify_8_d_a2.exs`（PASS）；`poc/lib/poc/research_workflow.ex`（ResearchWorkflow 模板 + ResearchAgent 定义）；`poc/lib/poc/actions/research.ex`（CreateOutline / PrepareRecruitMaterials / OpenQnA）。

---

## 10. 验证脚本与产出文件清单

### 验证脚本（`poc/scripts/`）
| 文件 | 对应验证项 | 状态 |
|---|---|---|
| `verify_1_dag.exs` | 1 DAG 执行 | PASS ✅ |
| `verify_2_gate.exs` | 2 Workflow 层人工门控 | PASS ✅ |
| `verify_2_agent.exs` | 2 Agent 层 saga 绕行 | PASS ✅ |
| `dbg_ran_filter.exs` | 2 根因双向证明（ran_nodes 过滤开关） | 复现/修复 |
| `verify_3_ash.exs` | 3 ash_jido 同步写 | PASS ✅ |
| `verify_4_signal.exs` | 4 异步 Signal 订阅 | PASS ✅ |
| `verify_5_partition.exs` | 5 partition + Thread 审计 | PASS ✅ |
| `verify_6_g1_hibernate.exs` | POC-2 G1 waiting 持久化 hibernate/thaw（A1-A5） | PASS ✅ |
| `verify_7_g2_journal.exs` | POC-2 G2 Bus journal 重放 + 幂等（B1-B3） | PASS ✅ |
| `verify_8_d_a2.exs` | POC-2 教研 D-A2 定义一次多实例化复用（D-A2a~D-A2d） | PASS ✅ |

### 关键源码（`poc/lib/poc/`）
| 文件 | 说明 |
|---|---|
| `actions/enrollment.ex` | ValidateEnrollment / CreateEnrollment / NotifyCompleted |
| `enrollment_workflow.ex` | 报名 workflow DAG（Workflow 层验证用） |
| `enrollment_workflow_saga.ex` | saga 版 workflow + EnrollmentSagaAgent（Agent 层绕行） |
| `enrollment_ash.ex` | Poc.Accounts / Poc.Enrollment（Ash + AshJido） |
| `enrollment_followup.ex` | CreateFollowUp + EnrollmentFollowUpAgent（异步订阅） |
| `enrollment_partition.ex` | PartitionEnrollmentAgent（partition + thread 审计） |
| `enrollment_agent.ex` | 报名 workflow agent（JidoRunic.Strategy 版） |
| `enrollment_followup.ex` | CreateFollowUp（含 idempotency_key 幂等）+ EnrollmentFollowUpAgent（POC-2 新增） |
| `research_workflow.ex` | 教研 workflow 模板（ResearchWorkflow.build + ResearchAgent 定义，D-A2 新增） |
| `actions/research.ex` | CreateOutline / PrepareRecruitMaterials / OpenQnA（教研参数化 Action，D-A2 新增） |

---

## 11. 遗留风险与后续建议

1. **jido_runic Agent 层 join 缺陷**：建议向维护者反馈；CGC 侧在适配层内置"多信号分批 feed"集成测试。
2. ~~**waiting 持久化 hibernate/thaw、Bus journal 重放**~~：**已由 POC-2 实证 PASS（§9.6）**，人工审批门控的崩溃恢复与异步副作用可靠性从"设计假设"升级为"已验证"。剩余未覆盖项：
   - 报名截止 deadline 的 Schedule Directive 唤醒 → cancel 路径（G1 方案第 4 条建议项）未验证，建议 v1 用"恢复时检查 deadline → 超时则 Emit cancel"实现并补集成测试；
   - 生产数据层（Postgres）并发压测（G3）未做，行锁/唯一约束能力以生产压测为准。
3. **名额并发压测**：ETS data layer 验证了约束逻辑，真实并发能力以生产数据层（Postgres）压测为准（§9 G3）。
4. **幂等/补偿**：异步路径幂等键已验证可用（§9.6 B3）；**生产实现必须用 Postgres 唯一约束或 Redis 等持久存储承载幂等键，勿用 action 进程自建 ETS（owner 随进程销毁，§9.6 关键发现）**。
5. **命名建议**：jido_runic 1.0 已不同于 0.1.x；文档/代码中版本引用以 mix.lock 为准。
6. **定义复用已实证**（§9.7）：教研 workflow 定义一次、多 Event/Course 实例化复用已 PASS；参数化靠 run input（signal data → ActionNode params）注入，**无占位符替换机制**——若后续出现"运行期按配置改写 workflow 结构"的需求，需用 `Workflow.merge/2` 组合或业务层参数化（Action schema 声明），勿期望引擎提供模板变量。
