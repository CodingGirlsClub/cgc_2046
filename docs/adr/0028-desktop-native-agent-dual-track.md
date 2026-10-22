---
status: proposed
date: 2026-10-22
---

# ADR-0028：桌面客户端内建 Rust native agent，与 external agent 双轨并存

> 日期：2026-10-22 ｜ 状态：**草案（Proposed，待产品负责人确认后转 Accepted）** ｜ 决策者：用户（product owner）
> 关联：ADR-0001（BYO）、ADR-0003（pi 设计哲学）、ADR-0022/0023（本机 Host 与多 agent）、ADR-0024（技术栈）、ADR-0025（桌面内化 Host）、ADR-0026（注册表）、ADR-0027（分发）；架构脊柱 `_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（AD-4/AD-5/AD-15/AD-16/AD-17）

## 背景（Context）

桌面客户端目前是 ACP 客户端：`platform::acp` / `platform::agent` 经 stdio 驱动学员自装的外部 agent（OMP / Codex / Claude Code），模型额度、审批习惯、登录都留在外部 agent 里（ADR-0022 / ADR-0023 / ADR-0025）。架构脊柱 AD-4 因此明确写「不实现 native agent、LLM 客户端与工具沙箱」。

这条路径有三个产品缺口：

1. **小白不可用**：学员要先装 agent、自己准备模型 key 或订阅。对第一次接触 agent 的用户门槛过高，也没有可售卖的模型额度。
2. **体验不可控**：教学 prompt、工具、审批、错误文案都受外部 agent 版本与行为影响。ADR-0023 已记录适配器默认审批模式、guardian review 撞额度、SIGKILL 留孤儿等真实问题。
3. **多 mate 难扩展**：学习搭子之外的教研 mate、event mate 若继续走外部适配器，每类 agent 都要新增适配与回归成本。

Zed 的实践提供了直接参照：native agent 是进程内 Rust 实现，与 external agent 共用一套 `AgentServer → AgentConnection` 抽象与 UI；Provider 层是「纯数据 Model + Provider trait」，settings 驱动自定义 OpenAI-compatible provider，凭据进 keychain。CGC 在 2026-10-22 对话中确认：web 端 agent 冻结、后续退役；桌面端采用 native，external agent 保留；v1 不做订阅 OAuth；CGC 网关作为小白默认 Provider。

## 决策（Decision）

1. **双轨并存**：桌面端内建第一方 **native agent**（Rust，进程内）作为默认学习 agent；现有 **external agent**（ACP）路径保留为高级模式。与 Zed 同构：一个 UI 契约，两个实现。web 端 agent 冻结，只修安全问题，后续单独决定退役时间；`cgc-host` 不新增功能。
2. **统一边界**：UI 只消费现有 `HostEvent` / `HostCommand` 契约，不新增第二套对话 UI。新增 `NativeHost` 实现同一事件接口（进程内调用，无 stdio）；`AcpHost` 保持现状。agent 选择器照 Zed 的「+」菜单：**最上面是 CGC Agent（native），分隔符之后是 external agents，默认折叠**；native 为默认项。
3. **native agent 分层**（新增 crate，遵循 AD-1 与「出现第二个真实消费者再拆」）：
   - `agent_provider`：`LanguageModel`（纯数据）+ `Provider` trait（`stream_completion` 必填）+ 统一 Request / Event / TokenUsage / 错误分类 + 各 provider 适配；
   - `agent_core`：turn loop、会话状态机、取消、重试、compaction 挂点；
   - `agent_tools`：工具 trait、schema 规范化、审批决策、危险命令规则；
   - `agent_store`：本地会话持久化（SQLite）；
   - `agent_mcp`：MCP 客户端（平台工具与第三方 MCP server）。
   UI 仍在 `app`（chat 面板）与 `agent_chat`（domain 边界），沿用 AD-4 的模块归属。
4. **Provider 可配置**：照 Zed 的 `language_model_core` 四件套实现。首批：
   - 官方：**CGC 网关**（OpenAI 兼容，登录 token，订阅额度，小白默认）；
   - 国产 BYO：DeepSeek / 通义 / Kimi / GLM / 豆包 / 硅基流动（OpenAI 兼容 + 每模型 capability 覆盖）；
   - 海外 BYO：OpenAI / Anthropic / Google / OpenRouter；
   - 本地：Ollama / LM Studio；
   - 自定义：任意 OpenAI-compatible endpoint（含用户自己的中转站；CGC 不转售、不承担上游供给）。
   凭据：API key 存 keychain 且与 `api_url` 绑定；**CGC 网关用登录会话 token**，照 Zed Cloud 的鉴权模式：服务端签发短时 LLM token（Bearer），响应带 `expired/outdated` 信号或 401 时刷新并只重试一次；402 映射为「订阅/额度不足」，429 映射为限流，403 映射为重新登录。**v1 不做 ChatGPT / Claude 订阅 OAuth**；key 不进 settings 与日志，登出清理。
   模型目录：客户端内置可版本化 JSON（context / tools / vision / thinking / 价格可选）+ 远程增量覆盖 + 用户可手填自定义模型。用量：本地 `TokenUsage` 展示；网关模式服务端计量配额。
5. **工具与权限**：v1 工具为读文件、写 / 编辑、搜索、列目录、终端命令、课程与学习工具（经 MCP）、可选 web 搜索。审批沿用现有 permission 事件与卡片，危险命令内置规则。**OS 级沙箱（macOS Seatbelt / Linux bwrap / Windows WSL）在 P1 就要落地**，与终端工具同批交付；**沙箱不可用时（如 Windows 无 WSL）降级为逐条命令审批并显式提示风险**，不静默放行。参考 Zed 的实现路径但只取 approach（Zed 为 GPL-3.0-or-later，代码复用需人裁）。
6. **平台工具经 MCP 获取**：native agent 作为 MCP client，在启动会话时用 `learning_host` lease 连接 CGC MCP，只放行学习循环 5 个工具；不写用户 `mcp.json`。AD-5 的「唯一注入点」语义对 native 改为「客户端内 MCP 配置由 session 唯一签发」。
7. **会话存储**：native 会话只存本机（SQLite），不上传平台、不进遥测与日志；**不做应用层加密，依赖系统账户隔离**（数据库 0600、位于用户数据目录）；用户可清除。AD-16 从「客户端不落对话」改为「对话只存本机、由 native agent 持有；外部 agent 仍由各自持有」。
8. **CGC 网关**：作为 native 的默认 Provider 与商业化路径；服务端计量与配额，复用现有支付与 Oban。平台自此提供模型服务，需同步修订 ADR-0001 的边界与隐私 / 合规口径。
9. **变更审阅与 Checkpoint（P1，Git）**：照 Zed 的做法，每条用户消息绑定一个 Git checkpoint：turn 开始时用临时索引做快照（`add --update` + 未跟踪文件，排除 ignore 与 >2 MB 文件），`write-tree` 后创建 commit 对象，写入隐藏 ref `refs/cgc/checkpoints/<thread>/<seq>`，不移动分支、不污染用户 index。Keep/Reject 走 `git diff` 与 `git restore --source`；Restore Checkpoint = 取消生成 → 截断会话 → `git restore --source <sha> --worktree .`，用户手改冲突时提示覆盖或跳过。每线程保留最近 50 个 ref，超限删 ref 并 `git gc --auto`；assistant 仓库上限 500 MB、课程仓库软上限 200 MB。**不建自建 blob 存储**——Git 已提供内容寻址、压缩、delta 与 GC。
10. **工作区与 Scope**：agent panel 全局可用（所有页面跟随 active tab），文件工作区按页面作用域解析：课程页用共享课程目录 `~/cgc2046_workspace/courses/<userId>/<courseId>`，其它页面用 `~/cgc2046_workspace/assistant/<userId>`（Windows 为 `%USERPROFILE%\...`）。native、external、web Host 与 OMP 插件共用这棵树，会话按 canonical cwd 分桶；沙箱根 = 当前 scope 目录；页面上下文只提供受限元数据（route / tab / 选中实体 id），不塞整页数据。**线程按 scope 一条**（课程一条、助手一条），切换 scope 载入对应线程，同一 scope 内切页面不换线程；assistant 工作区上限 500 MB。桌面 ACP 现用的临时目录是偏差（AD-17 #1），native 起改用共享树并建议 ACP 同批切换。
11. **Git 是硬前提**：native agent 要求学员安装 Git（onboarding 步骤）；没有 Git 时 native agent 不可用并给出安装指引（external agent 仍可用）。每个 scope 目录默认初始化仓库（`.gitignore` + 初始 commit；已有 `.git` 则尊重用户仓库；无 remote、禁止 push；`.git` 沙箱只读；破坏性 git 命令需审批）。Git 成为前提后，P1 checkpoint 直接使用 Git（临时索引 + 隐藏 ref + `git restore --source`），不再实现自建 blob 存储。
12. **迁移**：external 路径完全不动；native 在课程页按 workspace / 课程灰度开关接入；web 端 agent 冻结。

## 需要修订的既有决策

| 文档 | 现状 | 修订 |
|---|---|---|
| 脊柱 AD-4 | 不实现 native agent / LLM 客户端 / 工具沙箱；agent 唯一启动组件是 `platform::agent` | 改为双轨：native 默认、external 高级；`platform::agent` 继续负责 external；native 走新 crate |
| AD-5 | MCP 只在 ACP `session/new` / `session/load` 注入 | native 增加「客户端内 MCP 配置由 session 签发」；仍只用 `learning_host` lease |
| AD-15 | lease 由 `platform/agent` 持有 | native host 直接持有 lease；在客户端内做 5 工具清单核验 |
| AD-16 | 客户端不落对话 | native 会话本地存储；外部 agent 不变 |
| AD-17 | 桌面与 web 行为一致 | 仅对 external 路径适用；web agent 冻结后此条逐步作废 |
| ADR-0023 | 外部 agent 注册表 | 保留；会话指针扩展为 `(course, agent kind)`；native 不在注册表内 |
| ADR-0025 | 客户端自己就是 ACP Host；不打包 agent | 扩展为双宿主；native 随客户端发布 |
| ADR-0001 | 平台不运行模型、BYO | 保留 BYO；新增 CGC 网关作为可选 Provider（平台提供模型服务） |

## 否决的替代

- **只做 external + 官方网关**：小白仍需装 agent，体验受第三方版本影响，多 mate 不可控。
- **全云 agent**：token 成本、隐私口径、合规与工期都不划算（2026-10-22 讨论）。
- **native 但删除 external**：丢失已建能力与高级用户路径；Zed 也选择双轨。
- **v1 做订阅 OAuth**：ToS 与合规风险高，收益不匹配。
- **直接复用 Zed 代码**：GPL-3.0-or-later，先人裁；本 ADR 只取设计。

## 后果（Consequences）

**正面**：小白下载即用；agent 与客户端同版本，迭代不再受适配器影响；Provider / 审批 / 计量可自主；测试可用 FakeProvider 不烧 token；单二进制无 Node 运行时；多 mate 扩展为「定义 + 工具集」。

**代价 / 风险**：Provider 层、工具运行时、OS 沙箱、Checkpoint/diff、会话与评测是 8–14 人月量级长期投入（checkpoint 改用 Git 后省掉一套自建存储）；桌面 ACP 切共享工作区会导致旧会话指针失配（按 ADR-0022 口径从新对话开始）；**Git 安装成为 native agent 的准入门槛**，需要在 onboarding 与错误提示里讲清楚；assistant 工作区需要容量上限与清理入口。双轨维护两套会话 / 审批语义；模型目录与国内 provider 适配需持续维护；GPL 参考边界需人裁；平台提供模型服务引入隐私、合规与成本风险；单进程崩溃影响 UI，需要监督与恢复设计。

**回滚**：native 以 feature flag 接入；关闭后回到 ACP external 路径；CGC 网关可下线，BYO key 不受影响；external 路径与 `cgc-host` 保持现状。

## 落地

- **P0（2 周）**：ADR 定稿 + `agent_provider` 四件套 + FakeProvider + 一个真 provider（DeepSeek 或 CGC 网关）跑通流式文本。验收：不烧 token 的单测 + 可交互 demo。
- **P1a（6 周）**：`agent_core` turn loop + 读 / 写 / 终端工具 + 审批 + **OS 沙箱（Seatbelt / bwrap / WSL 同批，Windows 无 WSL 时降级审批）** + 本地会话 + **交互核心**（Commands / Events / confirm / notify + AppAction：打开页面、高亮）。验收：课程场景 E2E、审批卡复用、沙箱逃逸/越权用例、交互链路、崩溃恢复。
- **P1b（2–3 周）**：Checkpoint / diff（文件快照、Keep/Reject、Restore）+ 课程页灰度替换 ACP（开关）。验收：恢复/拒绝/大文件/工作区外路径用例、灰度验收。
- **P2（4–6 周）**：Provider 设置页、模型选择器、用量展示、compaction、CGC 网关配额与对账；**steering / follow-up、slash 命令面板、todo / plan / goal、subagent 进度、create_note AppAction**。验收：三平台真机（含沙箱在 Windows / Linux 的真机回归）。
- **P3**：多 mate 定义下发；OS 沙箱；web agent 退役评估。

## 参考

- 详细设计：`docs/plans/2026-10-22-1500-feat-native-agent-design.md`（分层、接口、turn 流程、工具/沙箱、存储、鉴权、测试、P0–P3）
- Zed Provider 层调研：`docs/tmp/agent-research/zed-provider-layer.md`（快照 zed main @2026-10-21）
- Zed 源码（Provider）：`crates/language_model/src/language_model.rs`、`crates/language_model_core/src/*`、`crates/language_models/src/{language_models.rs,provider/open_ai_compatible.rs}`、`crates/settings_ui/src/pages/llm_providers_page.rs`
- Zed 源码（网关鉴权）：`crates/language_models_cloud/src/language_models_cloud.rs:56-190,391-400`（`CloudLlmTokenProvider`、`authenticated_llm_request`、`x-zed-expired-token` / `x-zed-outdated-token` 重试、402 映射）、`crates/client/src/client.rs:350,1390-1400`（Bearer + 版本头）
- 前期调研：`docs/tmp/agent-research/{zed-native-agent.md,cgc-agent-current-state.md,pi-runtime-and-embedding.md,legion-eval.md,elixir-gateway-candidates.md}`
- 讨论页：`docs/tmp/answers/native-agent-provider-plan.html`
