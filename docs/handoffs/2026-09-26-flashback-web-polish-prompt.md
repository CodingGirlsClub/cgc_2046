# 交接提示词：web 端闪念间 / 金句墙 / 许愿树——重新梳理并改进功能、页面样式与视觉

> 用法：整段复制给接手的 agent。第 5 节「第八节第 4 问」如与你的决定不同，交出前改掉那一行。

---

你要接手 CodingGirlsClub/cgc_2046 仓库 **web 端（`web/`，Next.js）** 的「闪念间」「金句墙」「许愿树」三块：重新梳理一遍用户旅程、功能、页面样式与视觉，然后按优先级修复与改进。web 端要和已经上线打磨过的微信小程序（`miniprogram/`）配合：规则一致、术语一致、不能冲突；用户体验要好，可点的东西要有可供性。回复一律用简体中文。

## 1. 工作区与分支

- 基线分支是本机的 `feat/flashback-overnight`（**尚未推送**，已包含最新 `develop`）。不要直接改它，也不要在主 checkout（`/Users/ywen8/Code/github.com/CodingGirlsClub/cgc_2046`，停在 `develop`）上切分支或改文件。
- 新开 worktree 与分支，然后初始化（装依赖、链接 agent 配置、建本 worktree 专用数据库）：

  ```bash
  cd /Users/ywen8/Code/github.com/CodingGirlsClub/cgc_2046
  git worktree add ../cgc_2046-wt-web-polish -b feat/flashback-web-polish feat/flashback-overnight
  cd ../cgc_2046-wt-web-polish && bash scripts/worktree/setup-worktree.sh
  ```

- 另一个会话还在 `feat/flashback-overnight` 上工作。你的改动留在自己的分支，**不 push、不开 PR、不合并**，完成后由用户决定怎么合。

## 2. 必读

1. 根 `AGENTS.md`（授权表、安全红线、ego-browser E2E 分层）、`web/AGENTS.md`（这个 Next.js 版本有破坏性差异，写代码前先读 `web/node_modules/next/dist/docs/` 相关章节；GraphQL 契约层约定；测试在 `web/` 内跑；新增守卫必须做变异验证）、`miniprogram/AGENTS.md`（了解小程序怎么做的）；需要改后端时读 `backend/AGENTS.md`（错误码契约三处同步、变异验证、`mix precommit`）。
2. **梳理文档（主要参考）**：`docs/plans/2026-09-26-1157-audit-flashback-web-journeys.md`。它按「访客 / 持链接 / 已登录无档案 / 已登录有档案」梳理了页面、旅程、功能，对照小程序列了差距，缺口按 H / M / L 分级并附 `文件:行号` 证据。**先逐条核对是否仍成立**（代码已经变过，行号可能漂移），不要盲信。
3. 小程序现行视觉语言：`miniprogram/src/app.css` 顶部的 token 与注释；换肤原型与角色旅程盘点在远端分支 `prototype/flashback-light`：`miniprogram/prototypes/flashback-reskin.prototype.html`、`docs/闪念间-角色与旅程盘点.md`（`git show origin/prototype/flashback-light:<路径>` 读取）。
4. web 已做过的视觉修复：`git log --oneline --grep=视觉审计`（D7、D10 等），在其基础上统一，不要推倒重来。

## 3. 已完成，不要重做

- H0 私密愿望点开崩溃（11e3c141）。
- 「收好」统一规则（f97fe36b）：档案已属于别的账号 → `flashback_recover_account_conflict`，不悄悄挪；绑定即作废档案全部链接；web 收好被拒时按服务端错误码提示。
- 后台「单人重发」与全局守卫（2026-09-26）：`web/lib/graphql/schema-contract.test.ts` 会用后端 SDL 校验 `web/lib/graphql/` 下每一份文档——新增或修改文档后它必须保持绿。
- 找回只收邮箱（`RecoverForm` 的 `phoneEnabled` 默认关；手机号代码刻意保留，**不要删**）。
- 以上几处 web 改动（私密愿望弹窗、收好被拒提示、邮箱找回表单）目前只有组件测试，**还没在浏览器里验收**——你的 ego-browser 走查请把它们一起走到，发现问题照常修。

## 4. 任务清单（编号对应梳理文档第六节）

**P0**

1. **H1 回到时间长廊的入口**：登录态导航与 `/flashback` 首页给已绑定用户「我的闪念间 / 进入我的时间长廊」入口；所有写「从『我的』进入」的文案改成 web 上真实存在的入口（`web/messages/zh-CN.json` 与 `en.json` 同步）。
2. **H2 已登录一键收好**：已登录时首程「收好」改用 `flashbackClaim(token)` 绑到当前账号（与小程序一致，不发短信、不切账号）；未登录才走手机号 + 验证码。**已绑定的档案不再出手机号表单**，改为「这张卡已经收进账号，登录即可查看」——首程进入结果目前没有绑定状态，需要在后端 `flashback_progress` 补一个 `bound` 布尔字段（改后端见第 6 节约束）。
3. **M5** 失效链接「已被收进账号」的登录链接带回跳（`next`）。
4. **M2** 「有新进展时，可选择接收提醒」是空头承诺：提醒方案未定（第 5 节），先删掉或改成真实说明。
5. **M1** 回访时的金句授权管理：绑定后（无 token、只有登录态）也能看到当前授权档、能改能关（后端 `flashbackSetQuoteLicense` 的 token 本就可选）；能力对齐小程序（三档切换、关闭、选句）。

**P1**：M4 寄出后调「当年答案」的雾（见第 5 节）、M8「已有回响」改用后端 `withEchoes`、M9 首页许愿树板块、M10 金句墙城市改用 `flashbackVoiceCities` 与服务端按城市筛选、M11「我的愿望」（对齐小程序 `flashback-my-wishes`）、L1、L2、L4、L5、L6、L7（许愿树分页，对齐小程序每页 24 条）。M6 换手机号见第 5 节。**M7 不做**：小程序的公开树同样不显示留言，两端一致。

**P2（产品未定，先不做）**：H3 附议在 web 是否开放、M12 卡片公开链接（见第 5 节）、L3 取消附议、L8 金句举报。其中 H3 先做最小止血：「去小程序出力」弹层要有真正能到达小程序的方式（小程序码或明确指引），长廊旧版里的附议按钮对未登录的持链接用户不要再报答非所问的错误。

## 5. 已定与未定的产品决策

- 已定：找回只收邮箱；档案不悄悄挪、绑定即作废全部链接；web 已登录收好改一键收好（P0-2）。
- **第八节第 4 问（交出前按用户选择改这一行）**：寄出后调雾——web 补齐；换手机号——两端都不做，把 web 上「去小程序更新」的误导文案改成「如需更换请联系我们」（小程序其实也没有这个入口）；卡片公开链接——暂不做，保留现有导出与系统分享。
- 未定（不要自己拍板，需要时停下来问用户）：附议 · 我能出力是否在 web 开放；提醒通道（邮件等）做不做。

## 6. 与小程序配合的硬约束

- 前后端共用一个 GraphQL：不改现有字段语义。需要后端改动（如 P0-2 的 `bound`）时：同一分支改后端 + 重新生成 `backend/priv/graphql/schema.graphql` + 小程序 codegen（`miniprogram/src/api/generated` 必须随之提交）；小程序单测与 `tsc` 保持全绿；新增用户可见错误码按 `backend/AGENTS.md` 三处同步（契约、web messages、小程序 `error-copy.ts`）。
- 术语与口径和小程序一致：时间长廊、收好、找回、寄出、雾 / 亮、附议 / 我能出力、回响、相册；同一件事两端规则一致（绑定冲突、找回只收邮箱、链接一次性、未寄出者在相册只显示姓氏）。
- 不改小程序代码；确有必要（两端共享的口径）时单独提交并说明原因。

## 7. 视觉与交互要求

- **先走查再动手**：用 ego-browser 按四种用户状态 × 桌面 / 移动（390px）逐页截图，列出样式与交互问题，和梳理文档的缺口合并成一份问题清单。
- **视觉语言对齐小程序语义**（不要求像素一致）：纸是底、墨是字、青只画山河；暗是暗房（时间胶囊、开卡层、首程）；**火 = 可以按的（每屏最多一处）**；**金 = 已经被点亮的**（回来的人、授权的句子、回响、选中结果）。
- **可供性**：能点的看起来就能点（按钮 / 链接形态、hover / focus / active / disabled 态、光标），不能点的不要长得像按钮；危险操作二次确认；主次操作层级清楚。
- **每个流程都有**：loading、empty、error（可重试）、success 反馈；**没有死路**——每个状态都有下一步（尤其已登录无档案、失效链接、附议引导）。
- **无障碍**：键盘可达、focus 可见、表单有 label、`role="alert"` 报错、正文对比度 ≥ 4.5:1、尊重「减少动态效果」。

## 8. 工作流程

1. 梳理：核对梳理文档 + 走查截图 → 问题清单。
2. **出计划并写明假设，发给用户确认后再改**：每项的改法、影响面（web / 后端 / 小程序 codegen）、验收方式。
3. 实现：一次一个问题，测试先行（先写会失败的测试）；新增守卫做变异验证（改坏 → 红 → 还原 → 绿，两步输出都留在会话里）。
4. 验收：
   - web：在 `web/` 内 `pnpm vitest`、`pnpm typecheck`、改动文件 `npx eslint …`、`pnpm check:i18n`（中英 key 同步、源码不留中文）。
   - 改了后端：`backend/` 内 `mix precommit`、`mix format --check-formatted`、`mix cgc2046.gen_error_codes_contract --check`、SDL 新鲜度。
   - 改了 SDL：小程序 codegen + `./node_modules/.bin/tsc --noEmit` + 单测。
   - E2E：ego-browser 按根 `AGENTS.md` 分层——结构 / 样式数值断言 → 交互走通（成功与错误分支都走）→ 截图视觉复核；四种用户状态都要走到。dev 环境：后端 `mix phx.server`、web `pnpm dev`（worktree 已自动隔离数据库）；登录态照根 `AGENTS.md` 的规则，临时改动必须恢复。

## 9. 提交与边界

- 中文 conventional commit（`feat(web): …` / `fix(web): …` / `style(web): …`），一个问题一个提交，commit 里写验证命令与结果；**不加任何 AI 署名**。
- 不 push、不开 PR；不改人工合并范围（`AGENTS.md`、`docs/agents/**`、`.github/**`、`backend/priv/repo/migrations/**`、各 lock 文件）；`pnpm install` 后提交前 `git checkout -- pnpm-workspace.yaml`。
- 不读 `.env` 等敏感文件内容；公开文档与代码注释不写内部标识（模板 ID、批次号、person_id、内部 URL）。
- 遇到规格冲突或看不懂的地方：停下，写清楚疑问和取舍，等用户回复。

## 10. 汇报

结束时列出：每个问题的处理结果（对应编号）、前后对比截图、验证命令与输出；再按 `CHANGES MADE` / `THINGS I DIDN'T TOUCH` / `POTENTIAL CONCERNS` 汇总。
