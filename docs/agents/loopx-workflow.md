# LoopX 工作流（Codex CLI）

读者：LoopX 主控会话（Codex CLI）与它拉起的子 agent。只记录当前实际在用的做法；能做什么、不能做什么以根 `AGENTS.md` 的授权表为准；gh 命令经 `gh-axi` 透传（见 `docs/agents/issue-tracker.md`）。

## 1. 角色与模型

- **主控**：Codex CLI 会话，LoopX agent `codex-cli-cgc-2046`，模型用 Codex 默认模型。负责认领 todo、triage、决定自己做还是派子 agent、验收结论、change-quality 收据、push + 开 PR、写回 LoopX。
- **主控跑在主 checkout**（`.loopx/`、goal state 与 LoopX 管理的项目 skill 都只在这里），主 checkout 保持在 `develop`、不切分支改代码；所有改动都在 worktree 里做，LoopX 命令用 `--repo-path <worktree>` 指向它。手动会话也用自己的 worktree，别在主 checkout 上切分支。
- **子 agent**：LoopX `multi_subagent` 放行的临时子 agent，最多 3 个同时运行——共享测试库、端口 4001、ego-browser 登录态是实际上限。模型统一用 goal 配置的子任务模型（`spawn_policy.model_config`），不在别处另设。每个子 agent 一个独立 worktree，只改分配给它的文件，可在 worktree 内本地 commit，不 push、不开 PR。
- 紧耦合的改动留在主控一条线里做；不为了"看起来在并行"而拆子 agent。

## 2. 任务来源与 todo 约定

- 只从带 `ready-for-agent` 标签的 issue 取活，一个 issue 一个 LoopX todo；todo 的 note 记 issue 号、分支、PR 链接。
- **动手前 triage**：用当前 develop 对证 issue 的每条断言（读代码 / grep / 最小复现），三选一——**仍成立** → 正常做；**已落地**（工作已随其他 PR 进 develop）→ 不做，把证据（`文件:行` / 命令输出 / 落地 commit）写进 issue 评论，建 user_action todo 请人确认关闭；**部分落地 / 前提变化** → 以取证为准调整范围，必要时建 user_gate todo 先与人对齐。**issue 是快照不是真相源。**
- **大改动先批 plan**：涉及多端、schema / migration、接口契约、lockfile 的改动，先把 plan 写进 `docs/plans/`（`YYYY-MM-DD-HHMM-<type>-<slug>-plan.md`），建 user_gate todo，批准后再实施；其余改动直接做。

## 3. 每条改动的闭环

1. **准备 worktree**：`git worktree add --no-track -b <branch> <worktree-root>/<slug> origin/develop`（所有 worktree 放同一个根目录，别散落），进去后跑 `bash scripts/worktree/setup-worktree.sh`：它会链接项目 skill、复制 `backend/.env`、装三端依赖，并用 `mix setup` 建好这个 worktree 自己的 dev 库（Postgres 需已启动）。
2. **实施与测试**：按根 `AGENTS.md` 的 Testing principles；worktree 自动使用自己的数据库，不用设环境变量（见 §6）。并行起服务时用 `PORT`（后端）与 `BACKEND_URL`（web）指向各自端口。
3. **端到端验收（按端）**：改动涉及哪一端，就在该端做真实验收——组件/集成测试不算，要跑真实运行面：
   - **web（改了 `web/` 的 UI/交互）**：Dev 服务（`pnpm dev`）+ ego-browser 分层验收（见根 `AGENTS.md`「E2E validation」）：L1 结构/样式数值断言（`getComputedStyle` / `getBoundingClientRect`）、L2 交互走通（成功与错误分支都要走）、L3 截图只兜底主观项；登录态复用 ego-browser 既有 profile，确需重置密码的验完**必须恢复原哈希**。
   - **miniprogram（改了 `src/` 或投影契约）**：构建 + 微信开发者工具模拟器实测（wechatide-skill / miniprogram-automator / `pnpm e2e`），console 与 network 取证；涉及订阅触点的要真实授权弹层验证。
   - **backend（改了 GraphQL 面或 MCP 工具面）**：dev 服务起来后用真实 GraphQL 查询/变更实测（curl 或 ego-browser network 面取证），MCP 工具经对应 transport 实调一次——不能只靠测试套件自证。
   - **纯 docs / scripts / 生成物**：豁免，写明「无运行面」。
   - **降级口径**：验收环境确不可用（GUI/服务起不来）时，写明「未覆盖面 + 已做的替代自证」，建 user_gate todo 由人判断放行与否；**静默跳过 = 回炉**。
   - **端口纪律**：`4001` 是 miniprogram dev 约定端口（`miniprogram/config/index.ts` 写死 `localhost:4001`）——验收/代理服务一律避开；「服务用完即关」只关自己起的进程（先记录 pid/端口），绝不杀端口上的陌生进程。曾有一次验收收尾关掉 4001，误伤用户在跑的小程序调试环境。
   - **登录态串行**：共享 profile 的 `localhost` cookie 跨端口共享，多个 agent 并行会互相顶会话——登录态验收同一时刻只允许一个 agent 持有。
4. **change-quality 收据**：在主 checkout 里对 worktree 的最终 diff 生成，范围以 `origin/develop` 为基线：

   ```bash
   loopx --format json change-quality prepare --goal-id cgc-2046-goal --repo-path <worktree> --base-ref origin/develop
   # 按 packet 审查后：
   loopx --format json change-quality record --goal-id cgc-2046-goal --repo-path <worktree> --base-ref origin/develop --result-json <result.json> --execute
   loopx --format json change-quality verify --goal-id cgc-2046-goal --repo-path <worktree> --base-ref origin/develop
   ```

   以 `verify` 通过为准；**不跑 `loopx canary premerge`**——它选的是 LoopX 自身仓库的检查脚本、默认以 `origin/main` 和当前目录为准，放在本仓只会产生无意义的失败。收据生成后再改代码即作废，重新 `prepare`。改动发生在验收之后时，看 `git diff --name-only <验收时的 SHA>..HEAD`：只涉及测试文件、生成物（SDL/codegen）、CI 配置、lint 清理 → 不重做验收；涉及 `backend/lib/`、`web/app/`、`web/components/`、`miniprogram/src/` → 重做对应端验收。

   - **safe-fix / 简化的禁区（pins）**：不得删除或放宽错误/界面文案（逐字）、守卫条件与不变量（白名单/豁免表/计数）、fail-closed 语义、testid、i18n key，以及为「单一真源」刻意保留的重复；不许放宽或删除任何断言（`refute` 尤其）。safe-fix 改了代码就重跑受影响的测试与变异验证（见 §6）。
5. **push + 开 PR**：`git push -u origin <branch>`；PR 正文写 `Closes #N`、改了什么、为什么、用户可见影响、验收证据与收据结论。
6. **pr-review**：跑 LoopX pr-review，评审发在 PR 上（自己的 PR 由 GitHub 限制，以 COMMENTED 形式发结论）。
7. **合并归人**：建 user_action todo「合并 PR #N」，然后继续下一个 todo。

- **发现必须有归宿**：每条发现要么修掉，要么写成 issue 评论，要么另开 issue（见 §7）；"报告里提过"不算处理。

## 4. 重建方式：索引层 3-way（不要 rebase）

worktree 基于旧 develop、而 develop 已经前进时：**不要 rebase**（改写已 review 的 commit，PR 侧还要 force push）。重建方式：

1. 用**临时 index**（`GIT_INDEX_FILE=<tmp>`）对 base/ours/theirs 逐文件跑 `git merge-file`，把合并结果写进临时 index；
2. 用 `git commit-tree` 把重建后的 tree 挂到最新 develop 上生成新 commit（保留原 commit 的 message/作者），再把 worktree 分支指过去；
3. 子 agent 已本地 commit 时**源 commit 直接用它的本地 commit**：`git diff --stat origin/develop <agent-commit>` 仍必须恰好等于本分支改动文件集、且不得携带生成物（build 产物等）；
4. **重建后逐文件核对**：`git diff --stat origin/develop <NEW_COMMIT>` 必须恰好等于本分支自己的改动文件集；多出的文件说明源分支携带了 develop 侧内容 → 用排除清单剔除后重建（实例：2026-09-17 一次重建把 21 个 develop 文件带进 PR，CI 才变红）；
5. 文件按三类分别处理：① develop 未动 → 取源分支版本；② 双方都改 → `git merge-file` 三方；③ develop 新增 → **绝不带进来**；
6. ②且 diff3 报冲突时：源分支**已手工合并过**该文件 → 整份取 worktree 侧（`TAKE_THEIRS`）；**没手工合并过就不要整份取**——做「develop 版本 + 本分支那几处编辑」的确定性合成，并用两条自证收尾：`diff origin/develop <合成结果>` 只出现本分支的 hunk；被改的语义块与源分支逐字一致。不要凭 diff 猜意图做二次手工编辑；
7. 非 ASCII 路径先 `git config core.quotePath false`，否则中文文件名在 `diff` / `ls-files` 输出里是八进制转义，脚本匹配不到。

- **脚本存放约定**：可复用脚本放 `scripts/worktree/`，不留 `/tmp` 路径依赖；新增脚本参数化（PR 号等）、零第三方依赖、`set -uo pipefail`。

## 5. 落地链（人合并，fail-closed）

- PR 由人合并，一律 merge commit（repo 已禁 squash/rebase，见根 `AGENTS.md`）。`scripts/worktree/ci-sentinel.sh` 会在 checks 全绿时**直接合并**，只给人用；LoopX 会话看 CI 用 `gh-axi pr checks <PR>`。
- develop 前进后，还没合的 PR 先按 §4 重建，再用 GitHub 的 update branch（`gh pr update-branch`，经 `gh-axi`）对齐新 develop。**直接把"已合并内容"推分支没用**：GitHub 仍判 DIRTY。
- **唯一容忍的失败：`ext` 单独红**（已知 flake）→ 重跑失败的 job，超过次数仍红按真实失败处理。
- 任何**其他失败**：先判定是 flake / 内容问题 / 基础设施门禁（见 §8），再决定重跑、回炉还是记录；内容问题回 §3 闭环，改完重新生成 change-quality 收据。

## 6. 验证纪律

- **变异验证**：新增守卫/断言必须验证"去掉修复或守卫就变红"；只"绿"不算钉住（做法见 `backend/AGENTS.md`、`web/AGENTS.md`）。
- **新断言要测接线，不只测 helper**：同一条守卫落在多个渲染点时，每个站点分别改坏一次、确认对应断言变红（实例：金额守卫在多个渲染点，逐点改坏验红）。
- **白名单/豁免表必须显式**：列出 + 计数，并守三条不变量：全集 ⊆ 已覆盖 ∪ 表；表 ⊆ 全集；表 ∩ 已覆盖 = ∅。改计数 = 有意承认一个新缺口（实例：通知模板 registry ↔ 小程序场景集合守卫）。
- **版本化资产改内容必须 bump 版本**：agent 会缓存的 playbook / 版本串，改了内容不 bump 版本，消费端永远看不到新口径——只在服务端兜底等于没修。
- **改 resource 的 graphql DSL（含 destroy action）→ SDL 与 codegen 产物一起提交**：backend 编译即写 `backend/priv/graphql/schema.graphql`（AshGraphql 编译钩子）；CI 有 SDL 新鲜度门禁（显式 `mix absinthe.schema.sdl` + `git diff --exit-code`，不受编译缓存影响）。SDL 是 `miniprogram/src/api/generated/*` 的 codegen 输入，两者随 DSL 改动一起提交，否则门禁红（2026-09-17 #684 落地）。
- **时区双向自证**：日期/时间断言的期望值用被测格式化函数现场算；改动后在 `TZ=UTC` 与 `TZ=Asia/Shanghai` 下各跑一次（CI 是 UTC）。
- **测试在自己的 worktree 里跑**：附属 worktree 自动用 `cgc_2046_test_<slug>`；在主 checkout 跑会用共享的 `cgc_2046_test`，与并发的其他测试互相污染（见 `backend/AGENTS.md`）。
- **验证命令**：后端 `cd backend && mix precommit`；前端 `cd web && pnpm test`。
- **迁移在克隆库上实跑**（`createdb -T <源库> <克隆库>` 后在新库上跑），不动共享/开发库。
- **生产只读普查**：一律用专用只读角色 `cgc_ro`（不是应用账号 `cgc_2046`）——表级零写权限才是硬保证（实测：即使 `SET default_transaction_read_only = off` 绕过 GUC，`UPDATE events` 仍 `permission denied`）。连接：容器 `cgc2046-backend-postgres` 内 `psql -U cgc_ro -d cgc_2046_prod`（容器内 trust），或 TCP 5432 + scram；**凭据在用户凭据库，不进仓、不进 issue/聊天**。
- 普查会话仍要 `BEGIN READ ONLY` + `SET LOCAL statement_timeout = '30s'`：GUC 是软防线、权限是硬防线，两条都要；只允许 SELECT/EXPLAIN，结果脱敏（uuid/邮箱占位）后再贴 issue；生产单机、无只读副本 → 低峰执行。

## 7. 发现怎么分流

- **必修**：阻塞正确性/安全/数据 → 就地修（回 §3 闭环）。
- **记录**：不阻塞但值得留痕 → 写进相关 issue 的评论；**决策记录进 ADR 或 issue 评论，不为"记录"单独开 issue**。
- **另开 issue**：独立可交付的问题 → 新 issue，**一个主题一个 issue**（不要塞进当前 PR 评论里消失）。

## 8. 反模式（都实际踩过）

- **只等子 agent 汇报、不主动查**：子 agent 完工 ≠ 被发现，它可能停在等待、或汇报里只有结论。主控按 §3 的节点主动查（`git status --short`、日志尾部、命令原始输出）。
- **把"已合并内容"直接推分支**：GitHub 仍判 DIRTY；§4 重建 + update branch 才是正解。
- **把 `mix hex.audit` 这类新发布的安全公告当成自己的代码问题**：先看是不是全局门禁（公告与本次 diff 无关 → 基础设施门，别改自己的代码去迎合）。
- **改了给 agent 消费的文案 / playbook 却不 bump 版本**：消费端读的是版本串，不 bump 就永远用旧口径。
- **把 issue 正文里的计数 / 挂载点当最新事实**：issue 是快照不是真相源；先在仓库取证，允许用证据否掉 issue 的建议。
- **issue 已落地仍照做**：PR 未写 `Closes #N` 时 issue 会滞留；动手前必须按 §2 triage 自证，别对着已修好的代码再写一遍。
- **只测 helper / 只跑一次绿灯就宣称钉住**：缺变异验证（见 §6），没改坏过就不算守卫。
