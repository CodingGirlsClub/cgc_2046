# ADR-0003：基于 pi 设计哲学重构 CGC 架构方向

> 日期：2026-08-05 ｜ 状态：**已接受（Accepted，方向性）** ｜ 决策者：用户（方伯）+ Leader
> 关联：ADR-0001（BYO/MCP server）、ADR-0002（workflow-first + Jido）、issue #85（学习 Pi，重构 CGC 的架构设计）、Spec #22
> 学习来源：pi-book 32 章（https://zhanghandong.github.io/pi-book/）+ 本地 pi-mono repo 四层架构源码印证

---

## 背景（Context）

ADR-0001/0002 已确立 BYO + workflow-first + Jido 的架构骨架，6 个端到端切片（A-F）按 Spec #22 推进。在学习 pi（一个生产级 coding agent runtime）的设计哲学后，发现 CGC 现有架构在"薄内核"这条路上有三处没走到底：

1. **C（引擎）与 E（业务 workflow）的边界靠 ADR 纪律维持，没有代码级强制**——引擎有内建本该外置的业务逻辑（审批状态机、MCP 调用编排）的风险。
2. **6 个 slice 各自加载配置，缺乏统一 Resource Loader**。
3. **架构层数超过当前产品形态（Web UI + MCP server）所需复杂度**。

pi 的尺子：用 ~3000 行核心抽象（24% 代码）驱动 100% 产品形态，核心只做三件事（跑循环、管状态、发事件），其余全部外置。本 ADR 记录"把薄内核走到底"的重构方向，作为 slice C/E 实现与后续重构的设计基线。

**与 pi 的本质差异**：CGC 是多租户 Web 平台 + MCP server + BYO；pi 是单用户本地 agent 工具。本 ADR 迁移 pi 的设计哲学，不照搬其包结构。

## 决策（Decision）

### 五条贯穿原则

| 原则 | 理由 |
|---|---|
| **核心极简** | 引擎只做：编排步骤循环 + 管执行状态 + 发生命周期事件。其余外置为可注册回调。pi 用 24% 代码驱动 100% 形态——引擎超这个比例就是内建了不该内建的。 |
| **能力外置** | MCP 工具注册、业务步骤、审批策略、审计日志不是引擎契约。通过事件+回调+注册表外置，不同租户可有完全不同实现而不改引擎代码。 |
| **声明式配置优先** | 审批规则、provider 选择、capability clamping 用 DSL/配置表达，不每次改 Elixir 代码部署。pi 的 Skill 用文档替代代码。 |
| **事件驱动解耦** | 审计、通知、衍生副作用通过事件订阅，不嵌入引擎核心。引擎只发事件，产品层决定记录什么、存哪、是否通知。 |
| **延迟加载与缓存** | tenant config 在 run 启动时一次加载缓存、provider capability 用 ETag 增量刷新且移出启动路径、MCP tool schema 在 prompt 里只注入元数据完整内容按需加载——稳定 prompt cache 前缀。 |

### 关键重构项

**高风险**

- **Provider Trust Registry（Slice A）**：tenant 注册自定义 MCP provider 时，信任决策存在平台全局命名空间（不可被 tenant 篡改），tenant 数据里只存 provider 引用。加载租户自定义扩展前先过信任闸门。pi 的 `trust.json` 存全局不存仓库内。

**中风险**

- **引擎收窄为纯编排核心（C+E）**：业务步骤外置为可注册 step handler。引擎只负责调度/持久化/发事件。Step handler 用**两阶段初始化**注册：先声明 schema+接口（throwing stub），启动完成注入真实实现。
- **审批策略外置为 beforeToolCall 钩子（B）**：不内建审批状态机，用声明式 DSL 描述审批规则。不同租户可有完全不同策略。
- **checkpoint 剥离出引擎核心（C）**：checkpoint/摘要逻辑作为引擎之上的产品层服务，引擎只提供 `transformContext` 回调。支持增量更新。
- **MCP 工具执行器可插拔（C/D）**：开发模式本地直连、单租户进程内、多租户 SaaS 隔离沙箱——切换不改工具定义和调用方。

**低风险（分批）**

- 配置三层深度合并（A）：平台→tenant→workspace；默认值写在 getter 不写进数据库字段。
- MCP 为 Skill 式注入（D）：纯配置/声明式，不内建进引擎；provider 注册表升级为带 capability 声明的结构化注册。
- ETag 增量刷新 capability（D）：刷新移出启动路径，定时任务触发。
- capability clamping（E）：步骤声明所需 capability，引擎自动 clamp 到最近支持值而非硬失败。
- 三层 provider 选择（E）：平台内建 < tenant 配置 < 步骤显式指定。
- 统一 Resource Loader（A）：6 个 slice 各自加载 → 单一加载器，全局→租户→显式覆盖，单资源失败不阻塞。
- PromptAssembly 纯函数（C）：输入预加载配置+context+schema+profile，输出纯字符串，函数内不做 I/O；来源边界用 XML 标签不用 Markdown。
- prompt 里只放元数据（C）：MCP tool 只暴露 name+一行描述，完整 schema 在 tool_use 时按需传；动态内容移出 system prompt 到每轮 user message 开头。
- parent_step_id 树形历史（C）：评估 step 序列引入 `parent_step_id` 使历史成树；分支语义 tree/fork/clone。
- entry 类型分层（C）：WorkflowRun entry 按"是否参与 LLM context 构建"分三层；数据格式加版本号，梯级迁移。
- since 增量拉取（C）：状态 API 支持 since 参数，前端不全量拉历史。
- 输入归一化层（D）：MCP 工具入口 NFKC Unicode 归一化、空白/引号统一。
- per-resource 串行化队列（C）：同租户同资源状态变更用乐观锁+GenServer 串行化。
- checkpoint 请求隔离路由（C）：独立 sessionId + `cacheRetention:none`，摘要请求不污染主对话 prompt cache。
- 截断策略矩阵（C）：命令结果保留尾部、列表查询保留头部、审计日志保留两端。
- 租户扩展显式启用（A）：不自动扫描租户目录，避免隐式攻击面。

### 现有架构保留项

不因学 pi 而改掉 CGC 比 pi 更对的多租户设计：Ash+Postgres 数据层、BYO 范式、anubis_mcp 单 MCP server、RBAC 多角色并集、workspace_id 无状态 scope、确认流、Elixir/OTP 容错、WorkflowDefinition+WorkflowRun 分离、Signal/CloudEvents 异步、Agent=配置登记不含执行。

### 明确不做

pi 选择不做、CGC v1 也不做：step handler 沙箱隔离、extension 版本管理、依赖图解析、配置合并预览/解释、provider capability 注册时预验证、实时 capability 刷新进启动路径、审计嵌入引擎核心、全记录重写式 mutation、暴露原始 SQL 查询工具给 LLM、workflow 引擎执行任意 shell、审计与 LLM 上下文耦合、多 agent 编排进引擎核心、checkpoint/compaction 进引擎核心、system prompt 含动态内容。

## 后果（Consequences）

**正面**：
- 引擎与业务边界从"靠纪律"升级到"靠代码结构（behaviour + 两阶段初始化 + 配置引用）"强制。
- slice C/E 实现有了明确的"该不该内建"判定元规则：能不能用 event+callback+registry 组合出来，能就别内建。
- 多租户配置、provider 信任、capability 差异处理有了成熟参考模式。

**代价/风险**：
- 两阶段初始化、checkpoint 剥离等需要 slice C 实现时一次性落地，增加 #34-#39 的设计成本（但降低返工概率）。
- jido_runic 实验期（ADR-0002 已锁版本 + 适配层），本 ADR 的"能力外置"进一步降低对 jido_runic 内部 API 的耦合面，便于未来替换。
- 部分低风险项需跨 slice 协调（如统一 Resource Loader 横跨 A/C/D）。

## 三条核心洞察（实施元规则）

1. **核心是协议不是框架**：引擎做成"发事件+提供回调点"的协议，不做成"内建审批/MCP/审计"的框架。判断"该不该内建某功能"的元规则。
2. **每个不内建都对应一个用更底层机制组合出来**：遇到"要不要内建 X"，先问"能不能用 event+callback+registry 组合"——能就别内建。
3. **两阶段初始化是 Elixir 里强制依赖向内的落地手段**：step handler 启动期只声明契约，运行期注入实现，引擎永远只依赖契约不依赖实现模块。这把 ADR-0002"业务不得反向调引擎"从团队纪律提升到代码结构保证。

## 落地锚点

本 ADR 为方向性决策，具体落地锚于：
- **#34 WorkflowDefinition schema 设计**：蓝图是数据不是代码；Step handler 通过 behaviour + 两阶段初始化注册。
- **#35 WorkflowRun 状态机 + 引擎执行**：无状态引擎 + 有状态壳（WorkflowRun）；事件驱动；checkpoint 作为产品层服务经 `transformContext` 回调接入。
- **issue #85**：重构项的完整清单与风险分级。

## 决策依赖

- ADR-0001（BYO/MCP server）
- ADR-0002（workflow-first + Jido）
- pi-book 32 章设计哲学（第 30-32 章为核心）
- pi-mono repo 四层洋葱架构源码印证