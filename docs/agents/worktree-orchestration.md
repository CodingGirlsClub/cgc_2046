# Worktree Agent 编排 SOP

读者：本仓未来的编排者（orchestrator）与 worktree 实施 agent。只记录当前实际在用的做法，不写理想流程；命令细节（gh 经 `gh-axi` 透传、合并一律 merge commit、发布链）见根 `AGENTS.md` 与 `docs/agents/issue-tracker.md`。

## 1. 角色与沙箱分工

- **worktree agent**：改本 worktree 内的文件 + 在 worktree 内自证（`mix precommit`、`pnpm test`、ego-browser）。
- **编排者**：执行全部 `.git` 写操作（`add` / `commit` / `push` / PR / `merge`）。agent 的沙箱只能写 worktree 目录，**写不了 worktree 外的 `.git`**——所以 commit 不走 agent。
- 反向也成立：编排者**不能**改 worktree 里的文件（没有那个沙箱的写权限与上下文）。要改内容 → 派回 agent 改；编排者只移动 commit 与分支引用。
- 推论：**内容改动一律经 agent 落盘**，编排者负责版本控制与落地顺序。

## 2. 闭环（每条改动都要走完）

1. **`think`**：agent 只出方案，必须含决策点（推荐项 / 备选项 / 各自代价），不写代码。
2. **编排者逐条裁决**：每个决策点给出选择与理由；方向定了再实施（不要边做边改方向）。
3. **实施**：agent 按裁决改文件，并用命令原始输出自证（不是结论式汇报）。
4. **`check`**：agent 用 `check` 技能**只读**复核自己的 diff —— **报告制，先报不改**；发现先上报，等编排者裁决后再动手。
5. **编排者判定"无实质问题"才 commit/PR**；有发现就回炉：能修则修，非阻塞的记 issue。
- **不许把 `check` 的发现只留在报告里**：每条发现必须有归宿（修掉 / 写成 issue 评论 / 另开 issue）；"报告里提过"不算处理。

## 3. 重建方式：索引层 3-way（不要 rebase）

worktree 基于旧 develop、而 develop 已经前进时：**不要 rebase**（改写已 review 的 commit，PR 侧还要 force push）。编排侧重建：

1. 用**临时 index**（`GIT_INDEX_FILE=<tmp>`）对 base/ours/theirs 逐文件跑 `git merge-file`，把合并结果写进临时 index；
2. 用 `git commit-tree` 把重建后的 tree 挂到最新 develop 上生成新 commit（保留 agent 的 message/作者），再把 worktree 分支指过去；
3. **双方都改过的文件**：diff3 报冲突、而 agent 已手工合并过该文件时，按"整体采用其内容"处理（`TAKE_THEIRS`：整份取 worktree 侧内容）。不要二次手工编辑——编排者没有改文件的权限，也不该凭 diff 猜意图；
4. 非 ASCII 路径先 `git config core.quotePath false`，否则中文文件名在 `diff` / `ls-files` 输出里是八进制转义，脚本匹配不到。

## 4. 落地链（一条一条来，fail-closed）

- 一次只推进一条：合一条 → develop 前进 → 下一条先按 §3 重建、再用 GitHub 的 update branch（`gh pr update-branch`，经 `gh-axi`）对齐新 develop。**直接把"已合并内容"推分支没用**：GitHub 仍判 DIRTY。
- **只有 `0 failed` 才合**；合并一律 merge commit（repo 已禁 squash/rebase，见根 `AGENTS.md`）。
- **唯一容忍的失败：`ext` 单独红**（已知 flake）→ 重跑。
- 任何**其他失败立即停链**，由编排者介入判定是 flake / 内容问题 / 基础设施门禁（见 §7），判完再决定重跑、回炉还是记录。

## 5. 验证纪律

- **变异验证**：新增守卫/断言必须验证"去掉修复或守卫就变红"；只"绿"不算钉住（做法见 `backend/AGENTS.md`、`web/AGENTS.md`）。
- **时区双向自证**：日期/时间断言的期望值用被测格式化函数现场算；改动后在 `TZ=UTC` 与 `TZ=Asia/Shanghai` 下各跑一次（CI 是 UTC）。
- **后端测试带 `PASEO_BRANCH_NAME=<分支名>`**：否则测试库回落共享的 `cgc_2046_test`，与其他 worktree 并发时互相污染（见 `backend/AGENTS.md`）。
- **验证命令**：后端 `cd backend && PASEO_BRANCH_NAME=$(git branch --show-current) mix precommit`；前端 `cd web && pnpm test`。
- **迁移在克隆库上实跑**（`createdb -T <源库> <克隆库>` 后在新库上跑），不动共享/开发库。
- **生产只读普查**：一律用专用只读角色 `cgc_ro`（不是应用账号 `cgc_2046`）——表级零写权限才是硬保证（实测：即使 `SET default_transaction_read_only = off` 绕过 GUC，`UPDATE events` 仍 `permission denied`）。连接：容器 `cgc2046-backend-postgres` 内 `psql -U cgc_ro -d cgc_2046_prod`（容器内 trust），或 TCP 5432 + scram；**凭据在用户凭据库，不进仓、不进 issue/聊天**。
- 普查会话仍要 `BEGIN READ ONLY` + `SET LOCAL statement_timeout = '30s'`：GUC 是软防线、权限是硬防线，两条都要；只允许 SELECT/EXPLAIN，结果脱敏（uuid/邮箱占位）后再贴 issue；生产单机、无只读副本 → 低峰执行。

## 6. 发现怎么分流

- **必修**：阻塞正确性/安全/数据 → 就地修（回 §2 闭环）。
- **记录**：不阻塞但值得留痕 → 写进相关 issue 的评论；**决策记录进 ADR 或 issue 评论，不为"记录"单独开 issue**。
- **另开 issue**：独立可交付的问题 → 新 issue，**一个主题一个 issue**（不要塞进当前 PR 评论里消失）。

## 7. 反模式（都实际踩过）

- **只等 agent 汇报、不主动巡**：agent 完工 ≠ 被发现，它可能停在等待、或汇报里只有结论。编排者按 §2 的节点主动查（`git status --short`、日志尾部、命令原始输出）。
- **把"已合并内容"直接推分支**：GitHub 仍判 DIRTY；§3 重建 + update branch 才是正解。
- **把 `mix hex.audit` 这类新发布的安全公告当成自己的代码问题**：先看是不是全局门禁（公告与本次 diff 无关 → 基础设施门，别改自己的代码去迎合）。
