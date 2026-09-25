# omp-plugin（OMP 接入包）

CGC-2046 的 OMP（oh-my-pi）接入包，包实体在 `cgc-2046/`：主 agent（`agents/cgc.md`）+ 连接 onboarding skill + 质检 skill + `/cgc` 斜杠命令 extension，经 MCP 调后端。用户文档见 `cgc-2046/README.md`，维护规矩见仓库 `docs/agents/omp-plugin-maintenance.md`。

## 源与分发（最易踩的坑）

- **monorepo 是唯一真理**：只改 `omp-plugin/cgc-2046/`，别直接改分发 repo（`CodingGirlsClub/cgc-omp-plugins`）——分发 repo 由 sync workflow `rsync --delete` 同步，只改分发侧下次 sync 会被打回原形。
- 正确路径：monorepo 改 → PR 合并 → 验证 sync workflow 成功（`gh run list --workflow sync-omp-plugin.yml`）。

## 版本号纪律

- **不主动 bump 小版本**——用户明确要求才改；大版本（0.1 → 0.2）由产品决策驱动，不由工程习惯驱动。
- bump 时同步：`cgc-2046/package.json` version + `cgc-2046/CHANGELOG.md` 条目 + catalog 版本回填（sync workflow 自动）。仓库根 `CHANGELOG.md` 的端标签节点用 `[扩展 vX]`（发布纪律见根 `AGENTS.md`）。

## 验证

| 目的 | 命令 |
| --- | --- |
| 安装脚本六场景（沙盘 mktemp，不落真实 HOME） | `bash omp-plugin/cgc-2046/install.test.sh` |
| 守门配置写入三变体（同样沙盒） | `bash omp-plugin/cgc-2046/guard-config.test.sh` |
| 本仓库开发安装（dev MCP URL） | `bash omp-plugin/cgc-2046/install.sh install --url http://localhost:4000/mcp` |
| 卸载（只删本包文件与条目，保留备份） | `bash omp-plugin/cgc-2046/install.sh remove` |

## 实现陷阱（维护复盘结论）

- `ask` 在 headless 下抛 `ToolAbortError`（不是返回 auto_reply）——降级按小白默认引导。
- command handler 的 `ctx.cwd` 未验证，兜底 `process.cwd()`。
- `install.sh` 的 `merge_mcp_json` 重建 `cgc-2046` 条目时必须保留已有 headers（含 onboarding 写入的 token），否则升级抹 token。
- catalog schema：owner 是对象 `{name, email}`，description/version 在 metadata，author/license 属于 plugin entry 而非 catalog 顶层。

## 安全边界

- token 只落 `~/.omp/agent/mcp.json`（0600），不进对话、日志、其他文件。
- 高风险写操作走 two-tool 确认流：业务工具建 pending → agent 复述摘要 → `ask` 用户点选 → `confirm_operation` 触发 OMP 原生审批框 → 批准才落库；headless 子代理中 `confirm_operation` 直接拒绝。

## License

新依赖过根 `AGENTS.md` 的「依赖与 License 合规」门禁。
