# Plan 2026-08-20-009 · #218：工程尾款——CI 门禁对齐 + e2e 落地 + 前端残留清理

## 现状（issue #218 取证，2026-08-18 审计 + 本次核实）

1. **codegen 无 diff 门禁（F11）**：ci.yml miniprogram job 跑 `pnpm codegen` 但无 `git diff --exit-code`——生成文件漂移 CI 不红。
2. **check:ci 漂移（F16）**：`miniprogram/package.json` `check:ci` = codegen+typecheck+build:weapp，与 ci.yml miniprogram job 实际步骤（另含 licenses/test:unit/三端 build/check:diversion）不一致——两处清单无单一真源。
3. **e2e 未进 CI**：miniprogram 有 `e2e/run.mjs` 但 CI 不跑（注意：#99 已拍板小程序真实后端 E2E 归小程序阶段——**CI 落的是 Mock 模式 e2e**，不依赖真实凭据）；web 无 e2e（agent-browser 断言人工执行）。
4. **前端残留**：`web/app/(auth)/login/auth-form.tsx:249-251` mock 提交文案死代码（!onSubmit 分支——login 线 #250/#255 后实际形态需 writer 重核）；omp 帮助文案含开发 URL。
5. **check:graphql 未进 CI**：`miniprogram/scripts/check-graphql.mjs` 仅 dev 手工。

## 实施单元（单 PR，四块独立可评审）

### U1 codegen diff 门禁

ci.yml miniprogram job：codegen 步骤后加漂移检查——`git diff --exit-code` 直接上（生成产物入库的既有事实使该门禁可行；若 diff 命名空间问题则 `git status --porcelain | grep -v '^??' && exit 1 || true` 等价形态，writer 按 CI 实测选择）。

### U2 check:ci 对齐（单一真源）

方向：**ci.yml 调 `pnpm check:ci`**（而非反向让 package.json 复刻 YAML）——package.json `check:ci` 扩为 CI job 的完整步骤序列（codegen → diff 门禁(U1) → typecheck → licenses → test:unit → 三端 build → check:diversion → check:graphql(U5)），ci.yml 单步 `pnpm check:ci`。这样本地 `pnpm check:ci` = CI，漂移不可能。CI 仍需显式的步骤（如 checkout 缓存）保留 YAML，仅命令序列收敛。

### U3 e2e 进 CI（miniprogram Mock 模式）

miniprogram job 尾部加 `pnpm e2e`（`e2e/run.mjs` 以 `CGC_E2E_MOCK=true` 构建——现成语数，不碰真实凭据）。注意 CI 无微信开发者工具——**writer 先读 e2e/run.mjs 判定其运行前提**：若 run.mjs 依赖本机微信开发者工具 CLI 则此路不通，降级为只跑 mock 构建产物冒烟（`build:weapp` 已有，则 U3 改为 web 侧方案）；结论与证据写报告。

### U4 前端残留清理

- auth-form.tsx:249-251 mock 提交文案死代码（`!onSubmit` 分支）——login 线改造后该分支现状 writer 重核后删除或修整；连带其 i18n key（`submitNoteMock`）若无消费者一并清（messages zh/en 同步，i18n 覆盖门禁会兜底）。
- omp 帮助文案开发 URL：grep 定位（admin/openclacky 页或 components），替换为生产占位或删除。

### U5 check:graphql 进 CI

并入 U2 的 check:ci 序列（`node scripts/check-graphql.mjs`——前提核实：该脚本是否需要后端在跑；需要则记档理由不进 CI，只清 dev 手工用注）。

## 测试

- 改 ci.yml 后：观察本 PR 的 CI 运行即验证（miniprogram job 绿 = 门禁+对齐+e2e 全过）。
- 故意漂移验证（本地）：改一个生成文件 → `git diff --exit-code` 应红（writer 本地演示取证）。
- web 侧：`pnpm typecheck/lint/test/build` 全绿（U4 改动后）。

## 验收标准

1. PR CI 全绿（四 job）。
2. codegen 漂移本地演示红绿取证。
3. `pnpm check:ci`（miniprogram/）本地跑通且步骤 = CI。
4. auth-form 无 mock 死代码残留；开发 URL 清零。
5. e2e/check:graphql 进 CI 的裁决有明确结论（落地或记档不进的理由）。

## 非目标

- #99 小程序真实后端 E2E（小程序阶段）。
- web agent-browser 断言全量脚本化（#218 AC 说「至少其一」，U3 落 miniprogram 侧即满足；web 断言脚本化量大另立）。
- deploy.yml 改动（部署线在跑，不碰 .github/workflows/deploy.yml——本线只动 ci.yml）。

## 风险

| 风险 | 缓解 |
|---|---|
| e2e 依赖微信工具 CLI 不可 CI | U3 内置降级路径（writer 读 run.mjs 判定） |
| check:ci 收敛后 CI 行为变化 | PR 本身过 CI = 等价性证明 |
| auth-form 死代码实为活代码（login 线改造） | writer 重核现状再动；测试兜底 |
| 与部署线冲突 | 本线只动 ci.yml + web/miniprogram 源；deploy.yml/Dockerfile 不碰 |

## 关联

- Issue #218（关闭目标）；#208（母）；#99（e2e 边界）
