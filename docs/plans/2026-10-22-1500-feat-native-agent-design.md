---
title: "Native Agent - Design"
type: feat
date: 2026-10-22
topic: desktop-native-agent
execution: code
related:
  - docs/adr/0028-desktop-native-agent-dual-track.md
---

# Native Agent - Design

> 状态：设计稿（随 ADR-0028 一起评审）。依据：Zed main @2026-10-21 源码调研（`docs/tmp/agent-research/zed-native-agent.md`、`zed-provider-layer.md`）。Zed 为 GPL-3.0-or-later：本方案只取结构与策略，不复制代码。

## 1. 目标与非目标

**目标**

1. 桌面端第一方 native agent 可完成课程场景闭环：选模型 → 发消息 → 流式回复 → 调工具（读写文件、终端、课程工具）→ 审批 → 继续直到完成。
2. 用户可配置 Provider：CGC 网关（小白默认）、国产 BYO、海外 BYO、本地模型、自定义 OpenAI 兼容端点。
3. 与 external agent（OMP / Codex / Claude Code）双轨并存，共用一套对话 UI 与事件契约。
4. 会话只存本机，可恢复；token 用量可计量；网关鉴权用短时 LLM token。
5. 安全边界清晰：工具审批、危险命令规则、OS 沙箱（P1）、凭据只在 keychain、日志脱敏。

**非目标（v1）**

- 不做 LSP / 编辑器 buffer 深度集成（CGC 桌面不是编辑器；课程上下文由工具按需读文件）。
- 不做多 agent 编排（subagent / parallel）——P3 以后再评估。
- 不做 web 端 native agent（web agent 冻结）。
- 不做订阅 OAuth（ChatGPT / Claude 登录）。
- 不做云端会话存储与跨端同步。

## 2. 总体结构

```text
app（组合根、窗口、路由）
  └─ agent_chat（对话 UI 的 domain 边界：面板、审批卡、模型选择器）
       └─ agent_host（新：HostEvent / HostCommand 的两个实现：NativeHost / AcpHost 适配）
            ├─ agent_core（loop、thread、turn、取消、compaction 挂点）
            │    ├─ agent_provider（Model / Request / Event / Usage / Error + 各 provider）
            │    ├─ agent_tools（工具 trait、schema、审批策略、危险命令规则、沙箱包装）
            │    ├─ agent_store（SQLite 会话持久化）
            │    └─ agent_mcp（MCP client：平台工具 + 第三方 server）
            └─ platform::acp（现有 ACP 客户端，保留）
```

依赖方向：`app → agent_chat → agent_host → agent_*`；`platform::acp` 只被 `agent_host` 的 AcpHost 适配器使用，不被 native 路径依赖。新增 crate 的理由：独立依赖面（HTTP/SSE/SQLite/MCP）+ 需要并行开发与独立测试，符合 AD-1 的拆 crate 条件。

**双轨边界**：UI 只消费现有 `HostEvent` / `HostCommand`（`desktop/crates/platform/src/acp/connection.rs:124-191`）。`NativeHost` 在进程内实现同一事件接口；`AcpHost` 保持现状。agent 选择器照 Zed 的「+」菜单：最上面 CGC Agent（native），分隔符之后 external agents，默认折叠。

## 3. 数据模型与接口

### 3.1 Provider 层（agent_provider）

照 Zed 的四件套：Model 是纯数据，行为在 Provider 上，事件流是唯一输出。

```rust
pub struct ModelId(pub Arc<str>);
pub struct ProviderId(pub Arc<str>);

pub struct ModelCapabilities {
    pub tools: bool,
    pub streaming_tools: bool,
    pub images: bool,
    pub thinking: bool,
    pub effort_levels: Vec<EffortLevel>,
}

pub struct ModelLimits {
    pub context_window: u32,
    pub max_output_tokens: u32,
}

pub struct Model {
    pub id: ModelId,
    pub name: Arc<str>,
    pub provider_id: ProviderId,
    pub capabilities: ModelCapabilities,
    pub limits: ModelLimits,
    pub telemetry_id: Arc<str>, // "<provider>/<model>"
}

pub enum CompletionEvent {
    StartMessage { message_id: Arc<str> },
    Text(Arc<str>),
    Thinking { text: Arc<str>, signature: Option<Arc<str>> },
    ToolUse(ToolUse),            // 流式增量 + 完成标记
    Usage(TokenUsage),
    Stop(StopReason),
}

pub struct TokenUsage {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
}

pub enum ProviderErrorCategory {
    Authentication, PaymentRequired, Permission, RateLimit,
    Overloaded, ContextTooLong, InvalidRequest, Transport, Cancelled, Other,
}

pub trait Provider: Send + Sync {
    fn id(&self) -> ProviderId;
    fn models(&self) -> Vec<Model>;
    fn stream(
        &self,
        model: &Model,
        request: Request,
    ) -> BoxFuture<'static, Result<BoxStream<'static, Result<CompletionEvent, ProviderError>>, ProviderError>>;
}
```

- **认证抽象**：`CredentialSource::{ApiKey(ApiKeyRef), ShortLivedToken(TokenSource)}`。ApiKey 从 keychain 读，与 `api_url` 绑定；ShortLivedToken 由 `TokenSource` 提供（CGC 网关用）。
- **适配器**：`OpenAiCompatibleProvider`（覆盖国产与自定义 endpoint）、`AnthropicProvider`、`OpenAiProvider`、`GoogleProvider`、`OllamaProvider`、`CgcGatewayProvider`（OpenAI 兼容 + 短时 token + 结构化错误）。每个适配器把统一 Request 映射为 wire 请求，把 wire 流映射为 CompletionEvent。
- **工具 schema**：工具用 schemars 生成 JSON Schema，统一做 `normalize`（剥 `$schema/$title/$description`、内联 `$ref`），各 provider 映射时再包成自家格式。
- **模型目录**：客户端内置 `models.json`（provider / model / capabilities / limits / 可选价格），支持远程增量覆盖与用户手填模型；不做 Zed 那样的四套散落机制。

### 3.2 Thread 与 Entry（agent_core）

```rust
pub struct ThreadId(pub Arc<str>);

pub struct Thread {
    pub id: ThreadId,
    pub title: Option<Arc<str>>,
    pub model: SelectedModel,          // provider + model + thinking/effort
    pub entries: Vec<Entry>,
    pub usage_total: TokenUsage,
    pub created_at: i64,
    pub updated_at: i64,
}

pub enum Entry {
    User { content: Vec<UserContent>, at: i64 },
    Assistant { content: Vec<AssistantContent>, usage: Option<TokenUsage>, at: i64 },
    ToolCall { id: ToolCallId, name: Arc<str>, args: serde_json::Value, at: i64 },
    ToolResult { id: ToolCallId, ok: bool, output: String, at: i64 },
    Compaction { summary: String, replaced_entries: u32, at: i64 },
}
```

- `Thread` 是会话唯一事实源；UI 从 `HostEvent` 增量渲染，不反向改 Thread。
- `run_turn` 是唯一入口：构造请求 → 流式消费 → 工具调用（并发执行）→ 结果回灌 → 直到 `StopReason::EndTurn` 或达到 `max_steps`（默认 24）。
- 取消：每个 turn 一个 `CancellationToken`；provider 流与工具执行都响应取消，取消后发 `TurnEnd{cancelled:true}`。
- compaction：上下文超过模型 80% 时触发摘要（P2；P0/P1 先做硬截断 + 可配置上限）。

### 3.3 工具与审批（agent_tools）

```rust
pub trait Tool: Send + Sync {
    fn name(&self) -> &'static str;
    fn description(&self) -> &'static str;
    fn schema(&self) -> serde_json::Value;
    fn approval(&self, args: &serde_json::Value) -> Approval;
    async fn run(&self, args: serde_json::Value, ctx: &ToolContext) -> ToolResult;
}

pub enum Approval {
    Allow,
    Deny(String),
    Ask { title: String, options: Vec<ApprovalOption> },
}

pub struct ToolContext<'a> {
    pub workspace: &'a Path,
    pub cancellation: CancellationToken,
    pub sandbox: SandboxPolicy,
    pub mcp: Option<&'a McpRegistry>,
}
```

v1 工具清单：

| 工具 | 说明 | 审批策略 |
|---|---|---|
| `read_file` | 读工作区文件，限制大小与路径 | 只读，工作区内直接允许 |
| `list_directory` / `search` | 列目录、grep | 只读，直接允许 |
| `write_file` / `edit_file` | 写/编辑文件 | 默认 Ask；可按工作区 Allow |
| `terminal` | 执行命令 | 默认 Ask；危险命令硬拒绝；套沙箱 |
| `course_context`（MCP） | 课程、学习状态、playbook 等 5 个学习工具 | 由 learning_host lease 限定，直接允许 |
| `web_search`（可选） | 搜索 | Ask 或关闭 |

审批决策顺序：内置硬规则（危险命令、敏感路径）→ session 级 allow 列表 → 用户配置默认值 → Ask。审批 UI 复用现有 `PermissionRequested` 事件与卡片；「Allow for this session」写内存 allow 表，不落盘。

### 3.4 会话存储（agent_store）

SQLite（`<data_root>/agent/threads.db`），单文件、WAL：

```sql
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  title TEXT,
  model_provider TEXT NOT NULL,
  model_id TEXT NOT NULL,
  usage_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE entries (
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  kind TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (thread_id, seq)
);
```

- 写入按 turn 批量（流式期间不写），崩溃最多丢当前 turn 的增量；启动时扫描未完成 turn，标记为 interrupted（不做自动重放，避免重复副作用）。
- 删除：用户可清空单线程/全部；换账号时按账号隔离目录或清空。
- 加密：**不做应用层加密**，依赖系统账户隔离（2026-10-22 决策）；数据库文件权限 0600，目录在用户数据目录下。
- 不存任何 provider key / token；日志不写内容。

### 3.5 MCP（agent_mcp）

- 启动会话时用 `learning_host` lease 构造 MCP client（HTTP + Authorization），`initialize` 后 `tools/list`，只接受学习循环 5 个工具；数量不符则 fail-closed 并报错。
- 第三方 MCP server 预留配置入口（P3），v1 只接 CGC。
- 工具命名 `mcp:<server>:<tool>`，在 `agent_tools` 注册为普通工具；审批策略与本地工具一致（课程工具默认 Allow）。

### 3.6 网关鉴权（CgcGatewayProvider）

照 Zed Cloud 模式：

1. 客户端从会话服务取**短时 LLM token**（与账号会话分离，带过期时间）。
2. 请求带 `Authorization: Bearer <token>`；网关校验账号、订阅、额度。
3. 网关可回 `x-cgc-token-expired` / `x-cgc-token-outdated` 或 401 → 客户端刷新 token，**只重试一次**。
4. 错误契约：
   - 401 → `Authentication`（刷新失败则引导登录）；
   - 402 → `PaymentRequired`，body 含 `{ code, quota, upgrade_url }`（订阅过期 / 额度用尽分别给文案）；
   - 403 → `Permission`（设备撤销/无权限）；
   - 429 → `RateLimit`（含 retry_after）；
   - 5xx → `Overloaded`（可切备用模型）；
   - 400 上下文超限 → `ContextTooLong`（提示压缩或换模型）。
5. 退出登录 / 换账号 / 撤销设备：清 token 与缓存模型列表。

### 3.7 变更审阅与 Checkpoint（P1，Git）

2026-10-22 决策：Git 是 native agent 的硬前提，checkpoint 直接用 Git，不再自建 blob 存储。

**照 Zed 的实现**（只取 approach；Zed 为 GPL-3.0-or-later，不复制代码）：

- 每条用户消息绑定一个 checkpoint；turn 开始时用**临时索引**做快照，不污染用户的 index 与分支。
- 步骤：`git rev-parse HEAD` 记录基线 → `git add --update` 并收集未跟踪文件（排除 ignore 与超大文件）→ `git write-tree` → 创建 commit 对象（author 固定 `CGC Agent`，不移动任何分支）→ 写入隐藏 ref `refs/cgc/checkpoints/<thread-id>/<turn-seq>` 防止被 GC。
- 忽略规则：复用仓库 `.gitignore`，另加 checkpoint 专用忽略（二进制、压缩包、构建产物；单文件 >2 MB 不纳入）。Zed 用 `checkpoint.gitignore` + `--exclude-from` 实现，我们同样做一份。
- 会话与 checkpoint 的映射存 SQLite（只存 ref 与 sha，不存文件内容），与会话库同库。
- **Keep / Reject**：`git diff <sha> -- <path>` 展示变更；Reject 用 `git restore --source <sha> --worktree -- <path>` 恢复单文件；Keep 只做标记，不额外提交，避免污染历史。
- **Restore Checkpoint**：取消生成 → 截断会话到该用户消息 → `git restore --source <sha> --worktree .`（新建与删除文件一并处理）→ 二次确认。用户手改过的文件提示「覆盖 / 跳过」，不静默覆盖。
- **diff 展示**：`git diff --stat` + unified diff；UI 用文件列表 + 文本 diff（桌面端没有编辑器 buffer，不做 Zed 的 multibuffer 渲染）。
- **清理**：每线程只保留最近 50 个 checkpoint ref，超出的删 ref 后 `git gc --auto`；assistant 仓库整体上限 500 MB，课程仓库软上限 200 MB，超限提示；不删除用户分支或提交。
- **边界**：Git 不可用、仓库损坏或用户执行 `reset --hard` 后 checkpoint 可能失配，标记失效并提示重新初始化；checkpoint 只覆盖仓库内文件。

**为什么不自己存 blob**：Git 已提供内容寻址、压缩、delta 打包与 GC；自建 blob 还要做去重、压缩、引用计数与淘汰，和 Git 历史重复。Git 必装后没有理由两套并存。

```sql
CREATE TABLE checkpoints (
  thread_id TEXT NOT NULL,
  user_entry_seq INTEGER NOT NULL,
  ref TEXT NOT NULL,      -- refs/cgc/checkpoints/<thread>/<seq>
  sha TEXT NOT NULL,
  base_head TEXT,
  created_at INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'active', -- active | invalid
  PRIMARY KEY (thread_id, user_entry_seq)
);
```

### 3.8 工作区、Scope 与版本化（P1）

**Agent 在所有页面可用**：agent panel 是全局的（沿用导航规划里「Agent 全局跟随 active tab」），但文件工作区按**页面作用域（WorkspaceScope）**解析，而不是只服务课程页。

| Scope | 触发 | 路径 | Git |
|---|---|---|---|
| Course | 课程学习页（active tab 属于某课程） | `~/cgc2046_workspace/courses/<userId>/<courseId>/` | 每课程一个仓库 |
| Assistant | 其它所有页面（工作台、场次、课程目录、账户等） | `~/cgc2046_workspace/assistant/<userId>/` | 每用户一个仓库 |

Windows 路径以 `%USERPROFILE%` 取代 `~`。目录由后端核实过的 UUID 组成，页面传入的字符串不参与路径拼接；创建后 `canonicalize`，拒绝符号链接逃逸。

- desktop native、desktop external（ACP）、web `cgc-host` 与 OMP 插件共用这棵树（ADR-0022 / AD-19）；会话按 canonical cwd 分桶（ADR-0022 KTD6）。
- 现状偏差：桌面 ACP 目前用 `std::env::temp_dir()/cgc-desktop-chat`（`desktop/crates/app/src/root_view/controller.rs:367`），与 AD-17 #1 不符。native v1 改用共享树，建议 ACP 同批切换；旧指针失配按 ADR-0022 既有口径「从新对话开始」。
- **页面上下文**：每次 prompt 附带受限的 `PageContext`（route、tab、选中实体 id、页面标题；不放正文与原始数据），agent 通过 `get_page_context` 工具按需取；页面数据经平台工具查询（受权限约束），不把整页快照塞进 prompt。
- **线程归属**：thread 以 `(user, agent, scope_id)` 为键；切到不同 scope 时 agent panel 载入该 scope 的最近线程或新建；UI 显示 scope 芯片（「课程：xxx」/「助手工作区」）。同一 scope 内切换页面不换线程。
- **工具按 scope**：Assistant scope 只有平台通用工具（查询、导航、通知、账户只读）+ 本地文件与终端（限定 assistant 目录）；course 专属的 5 个学习工具只在 Course scope 注入；支付、账户变更等写操作始终需要用户显式确认。
- **沙箱根** = 当前 scope 目录；跨 scope 路径默认拒绝，v1 不提供显式授权。
- **清理**：assistant 目录设容量上限（建议 100 MB）与「清空」入口；课程目录随课程保留。

**版本化（Git，硬前提）**：2026-10-22 决策，native agent 要求学员安装 Git（有 agent 之后安装 Git 成本可接受）；安装 Git 作为 native agent 的 onboarding 步骤。

- 首次启动检测 Git：**没有 Git 时 native agent 不可用**，给出安装指引；external agent 路径仍可用。
- 每个 scope 目录默认 repo：目录不存在则创建 → `git init` → 写 `.gitignore`（`node_modules/`、构建产物、归档等）→ 初始 commit；已有 `.git` 则尊重用户仓库，不重复初始化。
- 仓库粒度按 scope；**不配置 remote、禁止 push**；author 用本地 `CGC Agent`；`.git` 在沙箱中只读；`reset --hard`、`push`、`clean -fdx` 等破坏性命令需审批。
- 用户手动改 Git 状态后 checkpoint 可能失配：提示重新初始化 checkpoint，不静默覆盖。
- 收益：学习者天然有版本历史与 diff；checkpoint 用隐藏 ref（3.7），不污染用户历史；课程导出、作品集、教研复盘都能复用。

## 4. 一次 turn 的完整流程

```text
UI（输入）→ NativeHost.prompt
  → agent_core: append User entry; 记录取消 token
  → context build：system prompt + agent 定义 + 最近条目 + 工具 schema
  → provider.stream(request)
  → 事件循环：
       Text/Thinking → HostEvent::Delta / ThoughtDelta
       ToolUse(complete) → 收集，流结束后并发执行
       Usage → 累加，发用量更新
  → 有工具调用？
       审批（如需）→ HostEvent::PermissionRequested → UI 决定
       执行（沙箱/超时/输出截断）→ 结果写 Thread
       → 回到 provider.stream（下一次迭代）
  → 无工具调用 → Stop(EndTurn) → 持久化 → HostEvent::TurnEnd
```

并发与超时：同一轮内多个工具并发执行（`FuturesUnordered`），单工具超时默认 120s、终端命令默认 300s（可由调用参数覆盖）；provider 请求默认 120s 无首 token 超时。

## 5. Prompt 与上下文

- system prompt 由三部分拼装：固定模板（沟通风格、工具使用规则、安全边界）＋ agent 定义（mate 的职责/工具白名单/模型策略，由后端下发）＋ 课程上下文（课程 id、学习目标摘要；正文由工具按需读取，不整段塞进 prompt）。
- 条目按时间顺序；工具结果默认截断（单条 16KB，保留头尾）并在截断处标注。
- 不在 prompt 中放动态秒级内容以外的大块数据；课程上下文由 `course_context` 工具按需取，保证 prompt cache 稳定。
- P2 引入 compaction：达到阈值时调 provider 生成摘要，替换中段条目。

## 6. 错误与 UI 映射

| 来源 | 分类 | UI |
|---|---|---|
| Provider 401/403 | Authentication/Permission | 去登录 / 检查 key |
| 402 | PaymentRequired | 订阅/额度不足 + 升级入口 |
| 429 | RateLimit | 稍后重试或切模型 |
| 5xx / 网络 | Overloaded/Transport | 重试 + 切备用模型 |
| 上下文超限 | ContextTooLong | 压缩/换模型 |
| 工具失败 | ToolError | 卡片内展示可操作错误，交回模型自修复 |
| 取消 | Cancelled | 气泡显示「已停止」 |

## 7. 安全模型

- **凭据**：API key 只进 keychain（与 URL 绑定）；网关 token 只在内存 + 会话刷新；退出登录清理；日志/遥测不写 key、不写对话内容。
- **审批**：工具默认最小权限；危险命令硬拒绝（参考 Zed 的硬编码规则思路，自己实现）；「Always allow」只允许用户显式点击。
- **沙箱（P1）**：macOS Seatbelt、Linux bwrap、Windows WSL；策略为工作区可写、`.git` 只读、网络默认禁止、临时目录受限。**沙箱不可用时（如 Windows 无 WSL）：降级为逐条命令审批并显式提示风险，不静默放行**（2026-10-22 决策）；用户可见「未沙箱执行」标记。
- **输出**：工具输出截断与转义；UI 渲染 markdown 走现有 SafeMarkdown 类入口。
- **权限边界**：native agent 不允许读 keychain 以外的用户配置；不写用户 `mcp.json`；不自主安装依赖。

## 8. 测试策略

| 层 | 方法 | 是否烧 token |
|---|---|---|
| Provider 适配 | SSE fixture 回放 + 事件序列快照 | 否 |
| Agent loop | FakeProvider 驱动多轮（文本/工具/取消/错误） | 否 |
| 工具 | 临时目录 + 假终端；路径逃逸、大小截断、危险命令 | 否 |
| 审批 | 策略表单测 + UI 事件 | 否 |
| Checkpoint / diff | 临时 Git 仓库：恢复、逐文件 Reject、未跟踪文件、ignored、>2 MB、用户手改冲突、ref 清理 | 否 |
| 沙箱（P1） | macOS/Linux 真机：写工作区、读 .git、网络、逃逸用例 | 否 |
| 网关鉴权 | 假 token 服务：过期头、401、402、429、刷新重试一次 | 否 |
| E2E | 课程页 feature flag 下用 FakeProvider 跑完整对话 | 否 |
| 真实 provider 冒烟 | 手动/夜间，1 条短请求 | 是 |

## 9. 里程碑与 P0 执行清单

| 阶段 | 内容 | 工期 | 验收 |
|---|---|---|---|
| P0 | Provider 四件套 + FakeProvider + 一个真 provider 流式 + 最小 UI | 2 周 | 不烧 token 的单测；真实 provider 冒烟；可交互 demo |
| P1a | turn loop + 读/写/终端 + 审批 + OS 沙箱 + 本地会话 + **交互核心**（Commands / Events / confirm / notify + AppAction：打开页面、高亮） | 6 周 | 课程 E2E；沙箱用例；交互链路；崩溃恢复 |
| P1b | Checkpoint / diff：Git 隐藏 ref、Keep/Reject、Restore；课程页灰度 | 2 周 | 恢复/拒绝/未跟踪/超大文件/冲突用例；灰度验收 |

**P2 进度（2026-10-23）**：
- **subagent（P2）**：`task` 工具 + `SubagentRunner`（宿主提供执行器）；`agent_core::run_subagent` 用独立 thread、只读工具、同一 provider/model 跑一次隔离 turn，返回最终文本；审批为 Ask。**进度事件已接**：`SubagentEvent::{Started, TextDelta, Finished}` 经 sink 回传，demo 打印到 stderr；HostState 新增 `SubagentCard`（任务、累计文本、运行/完成/失败），GPUI 面板渲染子 agent 卡片；**子 agent 事件直接写入当前 turn 的 AgentEvent channel，卡片实时刷新**（turn 结束后停止接收）。
- **compaction（P2）**：**摘要式压缩已实现**——请求前按 `context_window - max_output_tokens - 512` 切出较早历史，调用同一 provider 生成中文摘要，写入 `Entry::Compaction`（持久化到 SQLite），请求中保留「历史摘要 + 最近消息」；摘要失败自动回退硬截断；`TurnObserver::on_compaction` → `AgentEvent::ContextCompacted` → HostState 显示 system 通知。
- **slash 命令面板（P2）**：`agent_host::slash` 解析 6 个客户端命令（/help /clear /stop /tools /checkpoint /settings），GPUI 面板输入 `/` 时显示命令提示，命令不发给模型。4 项 host 测试。
- **AppAction（P1a）**：`agent_tools::action`（`AppAction` + `ActionSink`）与 `open_page` / `highlight_range` 工具；路由仅允许 `/` 开头（拒绝外部 URL），高亮校验路径与行区间；CLI 直接打印动作；**GPUI 已接真实动作**：`open_page` 经主窗口 `RootView::apply_native_agent_action` 导航，`highlight_range` 在主窗口内容区顶部显示高亮提示；找不到主窗口时回退为 system 消息。30 项 tools 单测。
- **todo / plan / goal**：`agent_tools::state`（`AgentState` + `SharedAgentState`）与 `todo_write` / `plan_write` / `goal_write` 三个工具；CLI 每轮打印状态摘要，GPUI 面板在状态变化时追加 system 消息。26 项 tools 单测。
- **follow-up**：`Agent` 支持 `queue_follow_up` / `follow_up_sender`，turn 结束后自动执行排队消息（最多 4 轮，`MAX_FOLLOW_UP_TURNS`）；`TurnObserver::on_follow_up_started` → `AgentEvent::FollowUpStarted`；HostState 归约时先落上一轮 assistant、再追加 user；GPUI 面板在 busy 时把输入转成 follow-up 排队。**steering 已实现**：`steer_sender` 在流式读取中被打断（保留已生成文本），记录 assistant 片段后追加用户消息继续；最多 4 次（`MAX_STEERS`）；`TurnObserver::on_steer_started` → `AgentEvent::SteerStarted` → HostState 先落片再追加 user；面板 busy 且输入非空时显示「打断」按钮。
Provider 设置（demo 面板内）——`agent_store::ProviderPrefs`（base_url / provider_name / model_id）落 `agent_prefs.json`；API Key 存系统钥匙串（account `native_agent_provider_api_key`），不落明文文件；面板可编辑并保存，重启 demo 窗口生效；启动优先 env，其次文件 + 钥匙串，最后回退 EchoProvider。12 项 store 单测。

**P1b 灰度（2026-10-23）**：灰度开关落本地偏好 `preferences.json` 的 `nativeAgentEnabled`（设置窗口新增 Native Agent（Beta）区块，可随时开关回退；env `CGC_NATIVE_AGENT` / `CGC_NATIVE_AGENT_DEMO` 仍可强制开启）。**课程页内联替换已实现**：学习页对话面板点「Native」后，侧栏内嵌 `NativeAgentView`（复用同一面板能力），头部「切回 ACP」一键回退；灰度关闭时入口隐藏、行为与 ACP 完全一致。

**P1b 进度（2026-10-22）**：`desktop/crates/agent_checkpoint`（cgc-agent-checkpoint）——临时索引 + `write-tree`/`commit-tree` + 隐藏 ref `refs/cgc/checkpoints/<thread>/<seq>`；snapshot / list / diff（临时索引对比工作区）/ restore / prune（保留 50 个）/ HEAD 漂移失效检测；大文件（>2 MB）与常见二进制/压缩包排除；6 项真实 git 仓库测试。会话映射进 `agent_store` 的 `checkpoints` 表（save/list/mark invalid，1 项测试）；GPUI 面板每轮建 checkpoint，并提供「撤销文件改动」；`changed_files` + `restore_file` 支持逐文件 Keep/Reject（面板内变更列表、回退按钮），HEAD 失配时拒绝恢复并提示重新初始化。待做：课程页灰度。
| P2 | Provider 设置 UI、模型选择器、用量、compaction、网关配额；**steering / follow-up、slash 面板、todo / plan / goal、subagent 进度、create_note AppAction** | 4–6 周 | 三平台真机 |
| P3 | 多 mate 定义下发、第三方 MCP、web agent 退役评估 | 待定 | — |

### P0 执行清单（2 周，单人可做）

| 切片 | 内容 | 验收 |
|---|---|---|
| T0 依赖与许可 | 新增依赖逐项过许可门禁（AGPL 兼容；GPL 类先人裁），版本 pin | 许可检查脚本通过；Cargo.lock 可审查 |
| T1 `agent_provider` 骨架 | LanguageModel / Request / CompletionEvent / TokenUsage + Provider trait + FakeProvider | FakeProvider 事件序列快照单测；trait 无 ACP / GPUI 依赖 |
| T2 OpenAI-compatible Provider | api_url / api_key（keychain 或 env）/ available_models；SSE 解析 text / thinking / tool_call delta；usage；401 / 429 / 5xx 映射 | 真实 provider 冒烟；流式与 token 计数正确；错误分类符合预期 |
| T3 最小 UI | Provider 配置入口、模型选择、对话输入、流式输出 | 可交互 demo；切模型生效；错误提示可读 |
| T4 计量与数据 | 每请求 TokenUsage 记录（内存即可）；模型选择持久化 | usage 累加单测；重启后选择保留 |

**P0 进度（2026-10-22）**：
- T0/T1/T2 完成——`desktop/crates/agent_provider`（cgc-agent-provider）已落地四件套、FakeProvider、OpenAI-compatible Provider（SSE 解析、thinking、tool_call 累积、usage、错误分类），19 项单测；
- T3 完成——`desktop/crates/agent_demo`（`cgc-agent-demo`）提供可交互 CLI demo：真实 provider（env 配置）、`--allow-tools`、`--once`、`--selftest`；另有 GPUI 最小窗口（`CGC_NATIVE_AGENT_DEMO=1 cargo run -p cgc-desktop-app`，离线时用 `EchoProvider`，配置 env 后接真实模型；含发送/停止、工具结果摘要）；
- T4 完成——`desktop/crates/agent_store`（`cgc-agent-store`）提供本地偏好存储（原子写入、损坏回退默认），模型选择落 `agent_prefs.json`；GPUI demo 启动时恢复、配置 provider 时保存；用量按轮次累计并在状态栏显示（内存态）。

**P1a 进度（2026-10-22）**：
- `desktop/crates/agent_core`（cgc-agent-core）：Thread/Entry + 单轮 loop（流式文本、用量累计、停止原因、取消、tool_call 收集），12 项单测；
- `desktop/crates/agent_tools`（cgc-agent-tools）：Tool trait、ToolRegistry、工作区路径约束（拒绝绝对路径与 `..` 逃逸）、审批分类、`read_file` / `list_directory` 只读工具，8 项单测。
- 工具执行已接入 loop：tool_call → 审批（Allow / Deny / Ask + 本会话授权缓存）→ 执行 → 结果回灌，最多 8 步；`prompt_with_tools` + `Approver` trait（Auto / Deny 实现），14 项单测。
- 工具集：`read_file` / `list_directory` / `write_file`（Ask）/ `run_command`（Ask，30s 默认超时、输出截断、工作区 cwd 约束）；16 项单测。
- 本地会话持久化完成——`agent_store::SessionStore`（SQLite `<data_root>/agent/threads.db`，schema 按 §3.4，WAL + 外键级联），5 项单测；GPUI demo 启动恢复上次会话（模型一致时）、每轮保存。
- OS 沙箱完成——`agent_tools::sandbox`：`SandboxPolicy`、macOS Seatbelt profile、Linux bwrap 参数、`CommandSandbox` 包装；`run_command` 带策略时自动进沙箱（macOS 实测沙箱内 echo 通过），Windows 降级为审批；demo/app 默认启用。
- P1a 切片全部完成；正式对话面板替换 demo 窗口、课程页 AppAction（open_page / highlight）留待后续。

**P0 不做**：工具执行、审批、会话持久化、MCP、沙箱、多 mate、网关服务端。

**P0 风险**：国内 provider 与 OpenAI 兼容层差异（tool_call 格式、thinking 字段）——P0 只要求文本流式，tool_call 解析保留 fixture；CGC 网关契约未定——先用 BYO provider 跑通；GPUI 线程模型——provider 调用放后台 executor，事件经 channel 回 UI。

## 10. 风险与待决

- **国内 provider 兼容性**：tool-call 流式、thinking 字段、并行工具调用差异大；先只保证文本 + 单工具调用，逐家补。
- **沙箱跨平台**：Windows（WSL）与 Linux（bwrap）真机成本高，P1 可能只能先保证 macOS。
- **上下文工程**：prompt、裁剪、compaction 直接影响质量与成本，需要评测集（P2 建立）。
- **双轨维护**：external agent 与 native 的会话/审批语义要长期并存，UI 必须能表达差异。
- **Checkpoint 依赖 Git 状态**：用户 rebase/reset/损坏仓库会让 checkpoint 失配；隐藏 ref 需要定期清理，否则仓库变大。
- **待决**：模型目录维护责任；native 会话是否需要加密存储；checkpoint/diff 是否 v1 就做；沙箱不可用时的降级策略。

## 11. 与 Zed 的差异

| 维度 | Zed | CGC |
|---|---|---|
| 编辑器集成 | buffer / LSP / diagnostics / action log 深度集成 | 不做，课程上下文按需读文件 |
| 会话存储 | SQLite threads.db | SQLite，本地、可清理、不上传 |
| Provider | 19 类 + settings 兼容层 | 首批 CGC 网关 + 国产 + 海外 + 本地 + 自定义 |
| 计量 | TokenUsage 事件，几乎无成本/配额 | 本地记账 + 网关配额与对账 |
| 审批 | tool_permissions + 沙箱 | 策略 + 沙箱 + 平台 5 工具 lease |
| Checkpoint / diff | Git checkpoint + ActionLog + 编辑器 diff | Git 隐藏 ref + 文件列表与文本 diff（无编辑器 buffer） |
| 多 agent | native + external 双轨 | 同构，external 保留 |
| 代码复用 | GPL-3.0-or-later | 只取设计，不复制 |

## 12. Client ↔ Agent 交互（借鉴 OMP 的四条通道）

来源：OMP v18.12.6 的 client-host 协议与扩展 UI（`docs/rpc.md`、`packages/coding-agent/src/modes/rpc/rpc-types.ts`、`packages/coding-agent/src/session/agent-session-events.ts`、`packages/coding-agent/src/extensibility/extensions/types.ts`）。只取协议形状与 UX，不引其 Rust crates。

**四条通道**（比单一「HostEvent 流」表达能力更强，建议在 native agent 里一次补齐）：

| 通道 | 方向 | OMP 形状 | CGC 设计 |
|---|---|---|---|
| Commands | Client → Agent | `RpcCommand`：prompt / steer / follow_up / remove_queued_message / promote_queued_message / abort / abort_and_prompt / new_session / open_session / switch_session / set_model / set_thinking_level / set_steering_mode / set_interrupt_mode / compact / set_todos / goal / bash / export_html / get_tree / get_state | `AgentCommand` enum，经 NativeHost 有界通道发送 |
| Events | Agent → Client | `AgentSessionEvent`：agent/turn/message 生命周期、message_update、tool_execution_start/update/end、auto_compaction、auto_retry、notice、goal_updated、todo_reminder、queue_update、subagent_lifecycle/progress、session_settled、prompt_result | 扩展现有 `HostEvent`；事件带 thread_id 与 seq，UI 只做归约渲染 |
| UI requests | Agent → Client | `extension_ui_request`：select / confirm / input / editor / ask / notify / setStatus / setWidget / setTitle / set_editor_text / open_url / cancel | `UiRequest` enum → GPUI 的 modal / picker / textarea / toast / 状态栏 / Dock / 窗口标题 / 系统浏览器 |
| Host tools | Agent → Client | `set_host_tools` + `host_tool_call` / `host_tool_update` / `host_tool_result` / `host_tool_cancel`；另有 host URI schemes | **AppAction 工具**：打开页面、定位并高亮、打开 diff、创建笔记、发起课程检查、展示审批；带 capability、审计与用户确认 |

**审批与运行中交互**（OMP `docs/approval-mode.md`）：

- 工具按 `read / write / exec` 三档分层；模式有 always-ask、always-ask-cached、auto-approve、yolo；界面选项为 Approve / Approve `<tool>` for this session / Deny。
- 用户在工具等待审批时继续输入 → 该消息视为 deny + steer，避免「先拒绝再解释」的来回；这个语义值得抄。
- Steering / follow-up 队列：运行中可插入补充要求（steer 立即生效或按 `interruptMode` 等待），也可排队 follow-up；`queue_update` 事件同步 UI。
- Todo / Plan / Goal 是三条独立的「客户端可见状态」：todo 分阶段任务、plan 文件与 handoff、goal 带 objective 与 token budget；都通过事件同步，客户端负责渲染。

**GPUI 落点**：

- Agent 跑在 `background_executor`；事件经 `async_channel`/`mpsc` 回 UI；每个 scope 一个 `Entity<ChatState>`，`cx.notify()` 局部刷新；每 turn 一个 `CancellationToken`，Stop 按钮直接触发。
- `UiRequest` 走一个 `Entity<UiRequestQueue>`：confirm → modal，select → picker，input/editor → Textarea，notify → toast，setStatus → 状态栏，setWidget → Dock。
- `AppAction` 执行前检查 capability 与 scope（课程 / 助手），写审计；改文件、导航、支付等敏感动作走审批；UI 线程用 `cx.update` 执行，不阻塞 agent 线程。
- 客户端按钮 → 快捷动作：把 page context（route/tab/选中实体/选区）拼成结构化 prompt 或调用 `AgentCommand`，不直接把整页数据塞 prompt。

**2026-10-22 交互面决策**：

1. **P1 交互面 = Commands + Events + UI requests（confirm / notify）+ AppAction**。不只是「命令 + 事件 + 审批」，按钮驱动与 Agent 操作客户端都要在 P1 有真实链路。
2. **AppAction 首批 = 打开页面 + 高亮范围**：两者不改业务数据模型、风险低、演示价值高；`create_note` / `todo` 放第二批（需要数据模型），运行课程检查放第三批（需要课程接口契约）。
3. **steering / follow-up 放 P2**：P1 先做「单轮 + 审批 + 停止 + 追加一句新 prompt」；队列语义（steer 立即生效、follow-up 排队、interruptMode）复杂度高，P2 再引入。

**P1 交互核心进度（2026-10-22）**：
- `agent_core::TurnObserver` + `prompt_with_tools_observed`：文本增量、工具调用/结果、审批请求、用量、结束事件；
- `desktop/crates/agent_host`（cgc-agent-host）：`AgentCommand`（prompt / stop / permission response）、`AgentEvent`、`HostState` 归约、`EventCollector`/`ChannelObserver`；测试覆盖事件序列与归约；
- CLI demo 用 observer 流式输出；GPUI 面板已切到 `HostState`：文本增量实时刷新、工具结果、用量、审批卡（允许一次 / 本会话允许 / 拒绝，经 `UiApprover` + oneshot 回填）。
- `ApprovalRequest` 补充 `tool_call_id`，审批响应可精确回填。

**优先级**：P1 做 Commands（prompt/stop/approve/set_model）、Events（文本/思考/工具/notice/queue）、UI requests（confirm/notify）、AppAction（open_page / highlight_range）；P2 加 steering/follow-up、slash 命令面板、todo/plan/goal、subagent 进度、checkpoint/diff UI、create_note；P3 再评估 side question、widget/status 扩展、host URI、voice。

**可借鉴的 OMP Rust 资产**（重写而非依赖，详见 `docs/tmp/agent-research/omp-rust-crates.md`）：pi-edit 的 hashline（编辑质量）、pi-shell 的结果模型（终端卡片）、pi-iso 的隔离后端形状（subagent 预留）、pi-walker 的扫描缓存（上下文枚举）、pi-predict 的输入预测（客户端提示，可选）。

## 参考

- `docs/tmp/agent-research/zed-native-agent.md`：Zed native agent 执行模型、工具、审批、沙箱、持久化、prompt、subagent
- `docs/tmp/agent-research/zed-provider-layer.md`：Provider 抽象、兼容层、认证、设置 UI
- `docs/adr/0028-desktop-native-agent-dual-track.md`：决策与修订清单
- P0 执行清单见本文件 §9（已从独立计划合并）
