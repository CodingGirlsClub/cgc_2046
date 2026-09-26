# 自动更新开放 PR 分支（auto-update-prs）

`.github/workflows/auto-update-prs.yml`（#937 合并后生效）。

## 行为

- 触发：push 到 `develop`、每 20 分钟 cron 兜底、手动 `workflow_dispatch`。
- 动作：对所有 open 且非 draft 的 PR 执行 `gh pr update-branch --merge`——把
  develop 的最新合并以 **merge commit** 并进该 PR 分支（符合仓库「一律
  merge commit、不 rebase」纪律）。
- 失败：自动在 PR 下评论 `develop 合并后自动更新分支失败…` 提示作者人工
  处理（通常为冲突或保护限制）。

## 影响

- 开发者不再需要在每个 PR 上手动点 Update branch。
- 分支保护规则与人工合并范围（`AGENTS.md`、`docs/agents/**`、`.github/**`、
  `mix.lock`、各 lockfile、迁移）不受影响——这些 PR 由人合并的原则不变；
  action 只做「develop → PR 分支」这个方向的合并，不动 PR 的 merge 决定权。
