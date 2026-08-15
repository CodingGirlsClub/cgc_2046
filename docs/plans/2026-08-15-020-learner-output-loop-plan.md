# Plan 020 · Workspace Agents 页与产出闭环（修订版：原地 + Agents 页）

- 日期：2026-08-15（修订：用户三轮讨论后重写，替代同名初版）
- 状态：待评审
- 决策依据：Scout020a/020b 取证 + 用户拍板（2026-08-15）：
  - **D-20a** 多宿主：「Agent 连接」是一等概念，OpenClacky/opencode/omp 平级为宿主选项，未来可扩展（Claude Code/Cursor 等）；
  - **D-20b** token 原地不动：MCP token 管理留在 `设置 → 集成 → Agents`（结构零搬迁，B1 靠入口提级解决）;
  - **D-20c** 学 Linear（linear.app/<ws>/agent 模式）+ 借鉴 codex-trajectory（隐私分级、事件账本、时间轴）：新增 workspace 级 `/w/[slug]/agents` 工作面。
- 关闭目标：#149（B1）、#150（C1 最小版）、#92、#93
- 非目标：Agent/Skill 资源与 `get_agent_instruction` 真实现（roadmap）；#83 Hub 重构；token 页/集成四 tab 的任何搬迁。

## 1. 分层模型（讨论结论固化）

| 层 | 归属 | 载体 | 内容 |
|---|---|---|---|
| 连接凭据 | 用户级数据，workspace 设置内管理（现状保留） | `设置→集成→Agents`（MCP/OpenClacky/opencode/omp 四 tab） | token 签发/撤销、各宿主接入引导 |
| Agent 工作面 | workspace 级 | **新页 `/w/[slug]/agents`** | 本工作台 agent 活动流、waiting 步骤交接 CTA、未连接引导 |

依据：token 校验只返回 user（`token.ex:274-295`），工具调用每次显式传 workspace_id（`wrapper.ex:38`）——凭据跨工作台复用，干活上下文在 workspace 语境，两层各自归位。

## 2. 已验证事实（scout，file:line 以 HEAD 为准）

- 活动流数据源已存在：`ToolCallLog`（`tool_call_log.ex:20-68`：user_id/tool/params-redact/result_status/error/latency/pending_id/时间戳；Redact 已滤敏感键）。**读面现状 platform_admin 专属**（moduledoc R10/R12 + policies），workspace 成员视角需新增查询。
- `mcp/page.tsx` token 管理交互完备（59-335），不动。
- 现有 OpenClacky 引导页 `openclacky/page.tsx:25-118` 三步卡（用户级一次性动作，零 workspace 特定内容）——Agents 页的「未连接」引导直接链到该 tab，不复制内容。
- waiting 步骤/CTA/schema 缺口同初版取证：`workflows/page.tsx` 只渲染 status/facts；Step 无 instruction/output_schema；GraphQL 无 steps 读取面（Scout020b 全量证据沿用）。
- codex-trajectory 借鉴（调研 2026-08-15）：隐私默认摘要级（事件名/时间/状态/受限摘要，全量需显式 detailLevel）；事件账本→时间轴 UI；`schemaVersion` 版本化输出；容错未知事件。MIT，仅借鉴设计不引代码。

## 3. High-Level Technical Design

### U1 入口提级（B1，#149）
1. workspace 侧边栏一级入口「Agents」→ `/w/[slug]/agents`（`workspace-nav.ts` + shell 导航）。
2. 品牌菜单（`workspace-switcher-menu.tsx:103-116`）加「Agents」项（当前 workspace 的 agents 页）。
3. 概览卡组（`/w/[slug]/page.tsx:149-199`）加「Agents 与助手协作」引导卡，链 agents 页。
4. 集成四 tab 原地不动；agents 页内「连接管理」链接指向 MCP tab（`/w/[slug]/settings/integrations/agents/mcp`）。

### U2 `/w/[slug]/agents` 工作面页（D-20c）
1. **活动流区**：新增成员可读 GraphQL 查询 `myWorkspaceToolCalls(workspaceId, first: 50)`——按 `params.workspace_id == ^workspace_id and user_id == ^actor.id` 过滤 ToolCallLog（**仅本人调用**，非全工作台流水——隐私默认最小面，对齐 codex-trajectory 摘要级理念）；返回摘要字段（tool/status/latency/inserted_at/error 摘要），**不返回 params**（即便已 redact，摘要级不展示参数）；policy：workspace 成员 + 仅本人。
2. **待办交接区**：本工作台 learning run 的 waiting/manual 待办步骤列表（复用 U3 步骤读取面），每项配**上下文交接按钮**——复制到剪贴板的交接文本：`workspace: <slug>(<id>) / run: <id> / step: <key> / 工具提示：用 save_step_output 写回该 step`（workspace_id 是助手调工具必需参数，交接文本把它直接送到用户手里）；多宿主文案「粘贴给你的 OpenClacky / opencode / omp 助手」。
3. **连接引导区**：无 active token 时展示（`fetchMyMcpTokens` 已可判断）；链 MCP tab 签发 + OpenClacky tab 三步引导；不重复引导内容。
4. 布局：活动流时间轴（codex-trajectory 形态：竖列事件卡，status 色点 + 耗时）+ 待办置顶。

### U3 步骤引导读取面 + workflows 页升级（#150 最小版 + #92）
1. 后端：`listWorkflowRuns`/`getWorkflowRun` 扩展 `definition { type }` + `steps { stepKey title type outputSchema }`（按 run 绑定 version 读，不读最新 definition）；授权复用 WorkflowRun 读 policy。
2. 前端 workflows 页：RunCard 加步骤条（facts 已有 step_key 推导完成集，待办高亮）；waiting/manual 旁平台引导文本 + CTA。
3. CTA（#92 修订版）：主动作 = 上下文交接复制（同 U2.2 文本，组件复用）；副链接「去 Agents 页」（工作面聚合）与「连接设置」（集成 tab）。多宿主文案；research 类型 run 不显示 CTA。
4. `get_agent_instruction` 接口语义留注释，不实现。

### U4 产物 schema 渲染（#93）
同初版：`node_def.steps[].output_schema`（name/type/label/optional，宽松校验兼容旧数据）→ steps 读取面带出 → 前端 `SchemaOutputList`（顺序/标签/类型渲染，可选缺失隐藏，schema 缺失回退 FactsTree）；`save_step_output` 写入语义零变化；React 文本节点，无 dangerouslySetInnerHTML。

### U5 测试 + e2e
- 后端：`myWorkspaceToolCalls` 三测（本人可见/他人不可见/非成员拒 + params 不在返回形状）；steps 读取面（成员可读/跨租户拒/版本绑定）；SDL 重生成。
- web：agents 页三区渲染与条件（有/无 token、有/无待办）、交接复制文本内容断言、CTA 条件（waiting·learning only）、SchemaOutputList 回退矩阵。
- e2e（结构断言）：侧边栏/品牌菜单/概览卡入口 → agents 页可达 → 交接按钮 clipboard 文本含 workspace id → workflows run 卡步骤条 + CTA → schema 渲染与回退。

## 4. 风险

| 风险 | 预案 |
|---|---|
| ToolCallLog 无 workspace_id 列，params 过滤走 jsonb 查询性能 | 量级小 + `first: 50` + inserted_at desc；若慢加 GIN 表达式索引（writer 用 EXPLAIN 判定，慢才加） |
| 隐私边界：活动流暴露他人调用 | U2.1 锁定仅本人；测试钉住 |
| definition version 漂移 | 读取面按 run.version；测试钉住 |
| CTA 交接文本被当 Agent 指令 | 文案标注「平台操作引导」；CONTEXT.md 记录语义 |
| agents 页与 #83 Hub 重构未来重叠 | 页面独立组件，入口卡只追加 |

## 5. 验收标准

1. 三个一级入口（侧边栏/品牌菜单/概览卡）可达 agents 页；集成四 tab 零变化。
2. agents 页：本人活动流（无 params）、待办交接（文本含 workspace id/run/step）、未连接引导三区正确渲染。
3. workflows 页：步骤条 + 平台引导 + 多宿主 CTA；schema 渲染与 FactsTree 回退。
4. #149/#150/#92/#93 关闭评论注明落地范围与多宿主抽象。
5. backend ×2 seeds + 契约 check + SDL 同步 + web 全套绿；e2e 过。

## 6. 实施顺序

U1 → U2 → U3 → U4 → U5 → 自查 → commit 不 push → `/tmp/cgc_2046-writer20-report.md`。

## 7. Assumptions（writer 验证，冲突即停）

1. ToolCallLog params 内 workspace_id 键名稳定（wrapper 落库格式）——writer 读 wrapper.ex 确认键名后定过滤表达式。
2. `myWorkspaceToolCalls` 新查询不与 admin 审计面（/admin/audit）冲突——那是 platform_admin 全量视角，本查询是本人 workspace 视角，policy 分开。
3. node_def jsonb 扩展无迁移；clipboard API 在 web 端可用（HTTPS/localhost）。
