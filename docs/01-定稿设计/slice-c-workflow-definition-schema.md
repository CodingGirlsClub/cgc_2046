# #34 WorkflowDefinition + 生命周期/版本 — Schema 设计

> 关联：ADR-0002（workflow-first + Jido）、ADR-0003（pi 启发的架构重构）、issue #34、#85
> Slice：C-1
> 状态：设计草案，待实现

---

## 1. 设计目标（来自 ADR-0003）

把 ADR-0003 的三条原则落到 #34 这第一个 slice C 资源上：

1. **蓝图是数据不是代码**：WorkflowDefinition 是声明式 DAG 蓝图（步骤顺序/类型/输入 schema），不是 Elixir 代码。运行时由引擎编译执行，改定义不改代码、不重新部署。
2. **核心是协议不是框架**：WorkflowDefinition 只描述"做什么步骤、什么顺序、什么类型"，不内建审批/MCP/审计逻辑——这些通过 step handler 外置。
3. **两阶段初始化 + behaviour**：step handler 注册时只声明契约（schema + 接口），运行期由引擎按契约调用实现模块。引擎永远不 import 业务模块，只依赖契约。

## 2. 领域定位

- **Domain**：`Cgc2046.Api`（tenant-scoped，与 spec 注释"M0.2 起租户资源逐个注册"一致）
- **领域目录**：`lib/cgc_2046/workflows/`
- **资源文件**：`lib/cgc_2046/workflows/workflow_definition.ex`
- **多租户**：`multitenancy attribute: :workspace_id`（与 WorkspaceMembership 一致，#34 issue 明确"归属 partition"）

## 3. WorkflowDefinition Schema

### 3.1 属性

| 属性 | 类型 | 说明 |
|---|---|---|
| `id` | uuid | 主键 |
| `name` | string | 蓝图名称（租户内可读） |
| `type` | atom | `:research`（教研）/ `:learning`（学习），#39 双 workflow |
| `version` | integer | 版本号，单调递增；改定义出新版本，不影响已开始 run（D-A2） |
| `status` | atom | `:draft` / `:published` / `:archived`，生命周期（#34 acceptance） |
| `input_schema` | json/map | workflow 输入参数 schema（JSON Schema 或 Ash map） |
| `node_def` | json/map | DAG 节点定义（步骤列表 + 顺序约束），**声明式数据**（见 §4） |
| `inserted_at` / `updated_at` | timestamp | |

### 3.2 node_def 的声明式结构（蓝图是数据）

`node_def` 是 JSON/Map 数据，不是代码。引擎运行时读取它驱动执行：

```elixir
%{
  steps: [
    %{
      id: "outline_design",
      title: "大纲设计",
      type: :human,              # 四分类之一（#36）：auto/human/gate/sub_workflow
      action: "Elixir.Cgc2046.Workflows.Actions.OutlineDesign",  # 原子引用实现模块，不 import
      action_type: :step_handler, # 引擎按 behaviour 调用
      input_schema: %{...},       # 该步骤输入参数 schema
      signal_match: nil,          # human 步骤的 SignalMatch 门控（#37），auto 为 nil
      next: ["content_review"]    # 顺序解锁（#36）：本步完成才可执行 next
    },
    %{
      id: "content_review",
      title: "内容评审",
      type: :auto,
      action: "Elixir.Cgc2046.Workflows.Actions.ContentReview",
      action_type: :step_handler,
      input_schema: %{...},
      next: []
    }
  ]
}
```

**关键约束**：
- `action` 是**模块名字符串**，运行时引擎 `Module.concat/1` 解析 + `behaviour` 校验，不编译期 import（ADR-0003 两阶段初始化）。
- `node_def` 是数据，可随版本演进；已开始的 WorkflowRun 快照当时的 `node_def`，改定义不影响运行中 run（D-A2）。

### 3.3 生命周期 + 版本管理

```elixir
actions do
  create :create do          # 默认 status: :draft, version: 1
  update :publish do         # draft → published；不可从 archived publish
  update :archive do         # published → archived；archived 不可再 publish
  update :new_version do     # 基于 published 定义创建 draft 新版本（version + 1）
end
```

状态流转（#34 acceptance）：
```
draft ──publish──► published ──archive──► archived
  ▲                   │
  │new_version        │
  └──── draft(v+1) ◄──┘
```

- 已 published 的定义可 `new_version` 出 draft 修订，改完再 publish。
- 已开始 run 持当时 published 版本快照，不随后续版本变动（D-A2）。

## 4. Step Handler Behaviour（两阶段初始化）

### 4.1 契约定义（引擎核心提供）

```elixir
# lib/cgc_2046/workflows/step_handler.ex
defmodule Cgc2046.Workflows.StepHandler do
  @moduledoc """
  Workflow step handler 契约（ADR-0003 两阶段初始化）。
  引擎只依赖本 behaviour，不 import 任何业务实现模块。
  """

  @type run_context :: %{
    run: Cgc2046.Workflows.WorkflowRun.t(),
    step: map(),
    facts: map(),
    actor: term(),
    tenant: term()
  }

  @type step_result :: {:ok, map()} | {:waiting, map()} | {:error, term()}

  @doc "步骤的输入 schema（注册期声明，throwing stub 阶段即可提供）"
  @callback input_schema() :: map()

  @doc "步骤能力声明（capability clamping，ADR-0003）"
  @callback capabilities() :: [atom()]

  @doc "执行步骤（运行期注入真实实现后调用）"
  @callback execute(run_context()) :: step_result()
end
```

### 4.2 两阶段初始化（ADR-0003 落地）

- **阶段一（注册期）**：step handler 模块 `@behaviour Cgc2046.Workflows.StepHandler`，提供 `input_schema/0` + `capabilities/0`。引擎/校验器此时可加载模块、读 schema、校验 `node_def` 里的 `action` 字符串是否实现该 behaviour——**不调用 `execute/1`**。
- **阶段二（运行期）**：WorkflowRun 执行到某 step，引擎 `Module.concat/1` 解析 `action` 字符串 → `Code.ensure_behaviour/1` 校验 → 调 `execute/1`。

**依赖方向强制**：引擎永远只 import `Cgc2046.Workflows.StepHandler`（behaviour），不 import `Cgc2046.Workflows.Actions.*`（业务实现）。业务模块也不 import 引擎——只实现 behaviour 回调。这把 ADR-0002"业务不得反向调引擎"从纪律提升到代码结构。

## 5. 与 #35-#39 的接口契约

#34 是 slice C 的内聚核心，下游 issue 的实现都基于本 schema：

| 下游 issue | 依赖 #34 的什么 |
|---|---|
| #35 WorkflowRun | 快照 `node_def` + `version`；执行时按 `step.action` 调 StepHandler.execute |
| #36 Step 四分类 | `node_def.steps[].type` 四值 + `next` 顺序解锁 |
| #37 人工步骤 waiting | `type: :human` + `signal_match`；checkpoint 经 `transformContext` 回调（ADR-0003） |
| #38 StepRole 授权 | 执行 prepare 阶段校验 actor 是否有 step 所需角色（外置为 beforeToolCall 钩子，ADR-0003） |
| #39 双 workflow 实例化 | `type: :research/:learning`；`type: :sub_workflow` step 引用另一 WorkflowDefinition |

## 6. 测试接缝（#34 acceptance）

`workflow_definition_test.exs`：
- `draft → published → archived` 状态流转
- 版本快照：new_version 出 draft(v+1)；已 published 不受新版本影响
- node_def 声明式校验：`action` 字符串指向的模块必须实现 `StepHandler` behaviour（阶段一校验）
- 租户隔离：跨 workspace 查不到对方定义

## 7. 不做（ADR-0003 明确不做清单）

- 不内建审批状态机（#38 外置为 prepare 阶段钩子）
- 不内建 MCP 调用编排（D 外置为 Skill 式注入）
- 不做依赖图解析（v1，`next` 线性顺序足够）
- 不做 step handler 沙箱隔离（v1）
- 不做 extension 版本管理（v1）

---

## ASSUMPTIONS I'M MAKING

1. jido / jido_runic / ash_jido 依赖在 #34 实现阶段添加到 `mix.exs`（当前未引入）。
2. `Api` domain 接收 workflow 租户资源；`Workflows` 领域目录新建。
3. `node_def` 用 Ash `:map` 或 `:json` 类型存（Postgres jsonb），不另起资源。
4. 版本管理用整数 `version` + `new_version` action，不做 git 风格 DAG 版本。

→ Correct me now or I'll proceed with these on implementation.