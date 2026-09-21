# OMP Plugin 维护规矩

## 版本号纪律

- **不主动 bump 小版本号**——只有用户明确要求时才改（如「发布 0.1.3 测试升级路径」）
- 大版本（0.1.0 → 0.2.0）由产品决策驱动，不由工程习惯驱动
- 每次 bump 必须同步：package.json version + CHANGELOG 条目 + catalog 回填（sync workflow 自动）

## Sync workflow 打回陷阱

- **monorepo 源是唯一真理**：`omp-plugin/cgc-2046/` 的内容必须改在 monorepo，不能只改分发 repo（`/tmp/cgc-omp-plugins`）
- 只改分发 repo 的修复，下次 sync 触发时会被 `rsync --delete` 打回原形（README trigger 垃圾、/cgc help 修复都踩过）
- 正确路径：monorepo 改 → PR 合并 → sync workflow 自动带到分发 repo

## 工作目录引导的设计意图

- `~/cgc2046_workspace` 的目的是：CGC 会话与其他工作分开（session 按目录分桶存储）、文件落点明确（课程草稿、导出材料）
- onboarding 首次连接后创建并引导（用 `ask` 分层：小白教命令，非小白一句话）
- `/cgc` 显示当前目录 + 非侵入提醒（不强迫，用户有自由）
- 不自动切换目录（OMP 不支持，且自动切换有副作用）

## 常见陷阱

- **ask 抛错（headless）**：不是返回 auto_reply，是抛 ToolAbortError——降级按小白默认引导
- **ctx.cwd 可能不存在**：command handler ctx 的 cwd 字段未验证，兜底用 `process.cwd()`
- **relay 主路径与手工路径共用步骤**：守门配置、工作目录引导都要在两条路径都有（relay 步骤 7/8 引用共用节）
- **catalog schema**：owner 必须是对象 `{name, email}`，description/version 在 metadata 里，author/license 属于 plugin entry 非 catalog 顶层
- **install.sh 的 token 保留**：merge_mcp_json 重建条目时必须保留已有 headers（含 onboarding 写入的 token），否则升级抹 token

## 验证要求

- 任何 monorepo 源的改动，PR 合并后必须验证 sync workflow 成功（`gh run list --workflow sync-omp-plugin.yml`）
- 任何分发 repo 的改动，必须同时 port 回 monorepo 源（否则下次 sync 打回）
- catalog 版本回填验证：`python3 -c "import json; print(json.load(open('.omp-plugin/marketplace.json'))['plugins'][0]['version'])"`
