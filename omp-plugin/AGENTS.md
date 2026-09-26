# omp-plugin（OMP 接入包）

CGC-2046 的 OMP（oh-my-pi）接入包，包实体在 `cgc-2046/`：主 agent（`agents/cgc.md`）+ 连接 onboarding skill + 质检 skill + `/cgc` 斜杠命令 extension，经 MCP 调后端。用户文档见 `cgc-2046/README.md`。

## 源与分发（最易踩的坑）

- **monorepo 是唯一真理**：只改 `omp-plugin/cgc-2046/`，别直接改分发 repo（`CodingGirlsClub/cgc-omp-plugins`）——分发 repo 由 sync workflow `rsync --delete` 同步，只改分发侧下次 sync 会被打回原形。
- 正确路径：monorepo 改 → PR 合并 → 验证 sync workflow 成功（`gh-axi run list --workflow sync-omp-plugin.yml`）。
- 已经直接改了分发 repo（如线上热修）时，必须同时 port 回 monorepo，否则下次 sync 被打回。

## 版本号纪律

- **不主动 bump 小版本**——用户明确要求才改；大版本（0.1 → 0.2）由产品决策驱动，不由工程习惯驱动。
- bump 时同步：`cgc-2046/package.json` version + `cgc-2046/CHANGELOG.md` 条目 + catalog 版本回填（sync workflow 自动）。仓库根 `CHANGELOG.md` 的端标签节点用 `[扩展 vX]`（约定见其头部）。

## 验证

| 目的 | 命令 |
| --- | --- |
| 安装脚本六场景（沙盘 mktemp，不落真实 HOME） | `bash omp-plugin/cgc-2046/install.test.sh` |
| 守门配置写入三变体（同样沙盒） | `bash omp-plugin/cgc-2046/guard-config.test.sh` |
| 本仓库开发安装（dev MCP URL） | `bash omp-plugin/cgc-2046/install.sh install --url http://localhost:4000/mcp` |
| 卸载（只删本包文件与条目，保留备份） | `bash omp-plugin/cgc-2046/install.sh remove` |
| catalog 版本回填（sync 成功后在分发 repo 的 clone 里跑，应等于 `cgc-2046/package.json` 的 version） | `python3 -c "import json; print(next(p['version'] for p in json.load(open('.omp-plugin/marketplace.json'))['plugins'] if p['name'] == 'cgc-2046'))"` |

## 实现陷阱（维护复盘结论）

- `ask` 在 headless 下抛 `ToolAbortError`（不是返回 auto_reply）——降级按小白默认引导。
- command handler 的 `ctx.cwd` 未验证，兜底 `process.cwd()`。
- `install.sh` 的 `merge_mcp_json` 重建 `cgc-2046` 条目时必须保留已有 headers（含 onboarding 写入的 token），否则升级抹 token。
- catalog schema：owner 是对象 `{name, email}`，description/version 在 metadata，author/license 属于 plugin entry 而非 catalog 顶层。
- onboarding skill 的 relay 主路径与手工路径共用「写入守门配置」「创建工作目录并引导」两节（relay 第 7、8 步引用它们）：改这两节即两条路径同时生效，新增同类步骤也要两条路径都覆盖。

## 工作目录引导（设计意图）

- `~/cgc2046_workspace` 把 CGC 会话与其他工作分开（OMP session 按目录分桶存储），课程草稿、导出材料也有明确落点。
- onboarding 首次连接后创建它，用 `ask` 分层引导：小白教命令 `cd ~/cgc2046_workspace && omp`，非小白一句话建议。
- `/cgc` 检测到不在该目录时用 `ask` 三选一——创建并切换 / 就在当前目录工作 / 取消，不强迫；headless 下 `ask` 抛错按「创建并切换」降级。
- 不自动切换目录（OMP 不支持，且有副作用）：「创建并切换」只建目录，并教用户退出后在新目录重启 `omp`。

## 安全边界

- token 只落 `~/.omp/agent/mcp.json`（0600），不进对话、日志、其他文件。
- 高风险写操作走 two-tool 确认流：业务工具建 pending → agent 复述摘要 → `ask` 用户点选 → `confirm_operation` 触发 OMP 原生审批框 → 批准才落库；headless 子代理中 `confirm_operation` 直接拒绝。
