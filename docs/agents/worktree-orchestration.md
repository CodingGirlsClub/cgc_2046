# Worktree Agent 编排 SOP

读者：本仓未来的编排者（orchestrator）与 worktree 实施 agent。只记录当前实际在用的做法，不写理想流程；命令细节（gh 经 `gh-axi` 透传、合并一律 merge commit、发布链）见根 `AGENTS.md` 与 `docs/agents/issue-tracker.md`。

## 1. 角色与沙箱分工

- **worktree agent**：改本 worktree 内的文件 + 在 worktree 内自证（`mix precommit`、`pnpm test`、ego-browser）；**可以在 worktree 内本地 commit**（2026-09-17 起历史约束放宽）。
- **编排者**：`push` / PR / merge / 分支引用移动一律归编排者——agent 的 git 权限到本地 commit 为止。
- 沙箱写 `.git` 的能力**按派单 provider 的 mode 判定，不按 worktree 位置**（git-dir 本就在 worktree 外：`git rev-parse --git-dir` 指向主仓 `.git/worktrees/<slug>`；mode 见 `paseo provider ls`）：
  - **omp（默认 `full`）可写**。2026-09-17 探针实测：`git add -A` → `add_exit=0`；`git commit --allow-empty` → `commit_exit=0`；`git reset --soft HEAD~1` → `reset_exit=0`，`git status` 回到干净、HEAD 回原 commit——index.lock / objects / refs 三处都写得动；
  - **dsh（默认 `default`）写不了**。2026-09-17 实测（另一 worktree）：`git add` 建不了 `.git/worktrees/<slug>/index.lock` → `Operation not permitted` → 回落"只改文件、由编排侧 commit"。**被拒一次就回落，不要反复提权重试**；
  - 实践口径：**omp 派单就要求 agent 自己 commit**（保留作者与 message，编排侧只 push / PR / merge）；dsh 派单走「只改文件、编排侧 commit」回落。
- 反向不变量：编排者**不能**改 worktree 里的文件（没有那个沙箱的写权限与上下文）→ **内容改动一律经 agent 落盘**，编排者只移动 commit 与分支引用。

## 2. Provider 与派单约定

- 默认派单：`paseo run --provider omp --model zhipu-coding-plan/glm-5.3`（2026-09-17 用户裁决；此前派出的 dsh agent 不追溯）。
- **一 issue 一 worktree**：`paseo workspace create --isolation worktree --mode branch-off --new-branch <b> --base origin/develop --worktree-slug <s> --title <t> --json`。
- **守望而不是轮询打扰**：agent 运行期间编排者不 busy-poll（打断其上下文）；用 `scripts/worktree/watch-idle.sh <agent-id> [timeout-s]`（包 `paseo wait`）阻塞到 idle，一 idle 立即 `paseo logs <agent-id>` 收报告。
- **CI 落地用哨兵**：`scripts/worktree/ci-sentinel.sh <pr> [head-branch]`——checks 全绿才 merge；真实失败立即打印失败 job + `--log-failed` 日志行并退出（fail-closed）；只有已知单点 flake（`ext` 单独红）自动 rerun（有次数上限）。

## 3. 闭环（每条改动都要走完）

1. **派单前 triage**：编排者用**当前 develop** 对证 issue 的每条断言（读代码 / grep / 最小复现），三选一——**仍成立** → 正常派单；**已落地**（工作已随其他 PR 进 develop）→ **不派单**，带证据（`文件:行` / 命令输出 / 落地 commit）与用户商量后按「已落地」关闭或改写 issue；**部分落地 / 前提变化** → 把差异写进派单提示词（以取证为准，不以 issue 正文为准），必要时先与用户对齐范围。**issue 是快照不是真相源；先取证，再决定要不要动手。**
2. **`think`**：agent 只出方案，必须含决策点（推荐项 / 备选项 / 各自代价），不写代码。
3. **编排者逐条裁决**：每个决策点给出选择与理由；方向定了再实施（不要边做边改方向）。
4. **实施**：agent 按裁决改文件，并用命令原始输出自证（不是结论式汇报）。
5. **简化 pass（`ce-simplify-code`）**：完整链条 `实施 → 简化 pass → 全量测试 + 变异复跑 → check → 编排者复核 → commit/PR`（2026-09-17 三条流 pilot，用户认可后入 SOP）。**check 必须在简化之后**：简化会改代码，改完的 check 结论才算数。
   - **scope**：`merge-base origin/develop HEAD`..HEAD；不要用 `origin/develop..HEAD`（develop 前进后会把别人的反向差异混进来）。
   - **pins（不可被简化掉）**：由本轮裁决生成，逐条列出——错误/界面文案逐字、守卫条件与不变量（白名单/豁免表/计数写死）、fail-closed 语义、testid、i18n key、以及为「单一真源」刻意保留的重复；**不许放宽或删除任何断言**（`refute` 尤其）。
   - **验证义务**：简化后**重跑**受影响站点的变异（改坏→必红→还原→必绿）与全量测试；只跑一次绿灯不算钉住（同 §6）。
   - **跳过条件**：纯生成物 / 文档 / CI 声明式配置（无实质人工代码）→ 按 skill 的 preflight 跳过并在报告里说明。
   - **findings 去向**：误报记 skipped；真问题但超 scope → 开 issue 或写进 PR（沿用"发现必须有归宿"）。
   - **实测收益**（2026-09-17 三条流，分别 applied 6 / 5 / 7）：抓过「说谎的注释」（文档写着旧判据）、「与事实不符的测试标题」、同名异义函数（`hasPaidOrder` vs `paidEnrollmentIds`）、N 卡×M 单的重复计算、以及一个真缺陷（`BusinessError.fields` 裸 atom 未 `List.wrap`，挂载冲突时 fields 被静默丢弃）。
6. **`check`**：agent 用 `check` 技能**只读**复核自己的 diff —— **报告制，先报不改**；发现先上报，等编排者裁决后再动手。
7. **编排者判定"无实质问题"才 commit/PR**；有发现就回炉：能修则修，非阻塞的记 issue。
- **不许把 `check` 的发现只留在报告里**：每条发现必须有归宿（修掉 / 写成 issue 评论 / 另开 issue）；"报告里提过"不算处理。

## 4. 重建方式：索引层 3-way（不要 rebase）

worktree 基于旧 develop、而 develop 已经前进时：**不要 rebase**（改写已 review 的 commit，PR 侧还要 force push）。编排侧重建：

1. 用**临时 index**（`GIT_INDEX_FILE=<tmp>`）对 base/ours/theirs 逐文件跑 `git merge-file`，把合并结果写进临时 index；
2. 用 `git commit-tree` 把重建后的 tree 挂到最新 develop 上生成新 commit（保留 agent 的 message/作者），再把 worktree 分支指过去；
3. agent 已本地 commit 时**源 commit 直接用 agent 的本地 commit**：`git diff --stat origin/develop <agent-commit>` 仍必须恰好等于本分支改动文件集、且不得携带生成物（build 产物等）；
4. **重建后逐文件核对**：`git diff --stat origin/develop <NEW_COMMIT>` 必须恰好等于本分支自己的改动文件集；多出的文件说明源分支携带了 develop 侧内容 → 用排除清单剔除后重建（实例：2026-09-17 一次重建把 21 个 develop 文件带进 PR，CI 才变红）；
5. 文件按三类分别处理：① develop 未动 → 取源分支版本；② 双方都改 → `git merge-file` 三方；③ develop 新增 → **绝不带进来**；
6. ②且 diff3 报冲突时：agent **已手工合并过**该文件 → 整份取 worktree 侧（`TAKE_THEIRS`）；**没手工合并过就不要整份取**——做「develop 版本 + 本分支那几处编辑」的确定性合成，并用两条自证收尾：`diff origin/develop <合成结果>` 只出现本分支的 hunk；被改的语义块与源分支逐字一致。不要二次手工编辑——编排者没有改文件的权限，也不该凭 diff 猜意图；
7. 非 ASCII 路径先 `git config core.quotePath false`，否则中文文件名在 `diff` / `ls-files` 输出里是八进制转义，脚本匹配不到。
- **脚本存放约定**：守望 / 哨兵这类可复用脚本放 `scripts/worktree/`（已有 `setup-worktree.sh`），不留 `/tmp` 路径依赖；新增脚本参数化（agent id / PR 号）、零第三方依赖、`set -uo pipefail`。

## 5. 落地链（一条一条来，fail-closed）

- 一次只推进一条：合一条 → develop 前进 → 下一条先按 §4 重建、再用 GitHub 的 update branch（`gh pr update-branch`，经 `gh-axi`）对齐新 develop。**直接把"已合并内容"推分支没用**：GitHub 仍判 DIRTY。
- **只有 `0 failed` 才合**（判定交给 §2 哨兵）；合并一律 merge commit（repo 已禁 squash/rebase，见根 `AGENTS.md`）。
- **唯一容忍的失败：`ext` 单独红**（已知 flake）→ 哨兵自动 rerun，超次数仍红按真实失败处理。
- 任何**其他失败立即停链**，由编排者介入判定是 flake / 内容问题 / 基础设施门禁（见 §8），判完再决定重跑、回炉还是记录。

## 6. 验证纪律

- **变异验证**：新增守卫/断言必须验证"去掉修复或守卫就变红"；只"绿"不算钉住（做法见 `backend/AGENTS.md`、`web/AGENTS.md`）。
- **新断言要测接线，不只测 helper**：同一条守卫落在多个渲染点时，每个站点分别改坏一次、确认对应断言变红（实例：金额守卫在多个渲染点，逐点改坏验红）。
- **白名单/豁免表必须显式**：列出 + 计数，并守三条不变量：全集 ⊆ 已覆盖 ∪ 表；表 ⊆ 全集；表 ∩ 已覆盖 = ∅。改计数 = 有意承认一个新缺口（实例：通知模板 registry ↔ 小程序场景集合守卫）。
- **版本化资产改内容必须 bump 版本**：agent 会缓存的 playbook / 版本串，改了内容不 bump 版本，消费端永远看不到新口径——只在服务端兜底等于没修。
- **改 resource 的 graphql DSL（含 destroy action）→ SDL 与 codegen 产物一起提交**：backend 编译即写 `backend/priv/graphql/schema.graphql`（AshGraphql 编译钩子）；CI 有 SDL 新鲜度门禁（显式 `mix absinthe.schema.sdl` + `git diff --exit-code`，不受编译缓存影响）。SDL 是 `miniprogram/src/api/generated/*` 的 codegen 输入，两者随 DSL 改动一起提交，否则门禁红（2026-09-17 #684 落地）。历史上"每个 worktree 编译一次就多一个脏文件"的现象已随门禁消失。
- **时区双向自证**：日期/时间断言的期望值用被测格式化函数现场算；改动后在 `TZ=UTC` 与 `TZ=Asia/Shanghai` 下各跑一次（CI 是 UTC）。
- **后端测试带 `PASEO_BRANCH_NAME=<分支名>`**：否则测试库回落共享的 `cgc_2046_test`，与其他 worktree 并发时互相污染（见 `backend/AGENTS.md`）。
- **验证命令**：后端 `cd backend && PASEO_BRANCH_NAME=$(git branch --show-current) mix precommit`；前端 `cd web && pnpm test`。
- **迁移在克隆库上实跑**（`createdb -T <源库> <克隆库>` 后在新库上跑），不动共享/开发库。
- **生产只读普查**：一律用专用只读角色 `cgc_ro`（不是应用账号 `cgc_2046`）——表级零写权限才是硬保证（实测：即使 `SET default_transaction_read_only = off` 绕过 GUC，`UPDATE events` 仍 `permission denied`）。连接：容器 `cgc2046-backend-postgres` 内 `psql -U cgc_ro -d cgc_2046_prod`（容器内 trust），或 TCP 5432 + scram；**凭据在用户凭据库，不进仓、不进 issue/聊天**。
- 普查会话仍要 `BEGIN READ ONLY` + `SET LOCAL statement_timeout = '30s'`：GUC 是软防线、权限是硬防线，两条都要；只允许 SELECT/EXPLAIN，结果脱敏（uuid/邮箱占位）后再贴 issue；生产单机、无只读副本 → 低峰执行。

## 7. 发现怎么分流

- **必修**：阻塞正确性/安全/数据 → 就地修（回 §3 闭环）。
- **记录**：不阻塞但值得留痕 → 写进相关 issue 的评论；**决策记录进 ADR 或 issue 评论，不为"记录"单独开 issue**。
- **另开 issue**：独立可交付的问题 → 新 issue，**一个主题一个 issue**（不要塞进当前 PR 评论里消失）。

## 8. 反模式（都实际踩过）

- **只等 agent 汇报、不主动巡**：agent 完工 ≠ 被发现，它可能停在等待、或汇报里只有结论。编排者按 §3 的节点主动查（`git status --short`、日志尾部、命令原始输出）。
- **把"已合并内容"直接推分支**：GitHub 仍判 DIRTY；§4 重建 + update branch 才是正解。
- **把 `mix hex.audit` 这类新发布的安全公告当成自己的代码问题**：先看是不是全局门禁（公告与本次 diff 无关 → 基础设施门，别改自己的代码去迎合）。
- **改了给 agent 消费的文案 / playbook 却不 bump 版本**：消费端读的是版本串，不 bump 就永远用旧口径。
- **把 issue 正文里的计数 / 挂载点当最新事实**：issue 是快照不是真相源；先在仓库取证，允许用证据否掉 issue 的建议。
- **issue 已落地仍照做**：PR 未写 `Closes #N` 时 issue 会滞留；派单前必须按 §3 triage 自证，别对着已修好的代码再写一遍。
- **只测 helper / 只跑一次绿灯就宣称钉住**：缺变异验证（见 §6），没改坏过就不算守卫。
