# Changelog

All notable changes to the CGC-2046 OMP plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.2] - 2026-09-21

### Added

- 工作目录引导：onboarding 首次连接后创建 `~/cgc2046_workspace`，用 `ask` 分层引导（小白教命令 `cd ~/cgc2046_workspace && omp`，非小白一句话建议）
- `/cgc` 显示当前目录 + 非侵入提醒（如果不是 `~/cgc2046_workspace`，提醒「建议在 `~/cgc2046_workspace` 跑 OMP」）

## [0.1.1] - 2026-09-21

### Fixed

- `/cgc help` 技术细节节适配 plugin 安装：卸载命令改 `omp plugin uninstall cgc-2046@cgc-omp-plugins`（原 install.sh remove），文档链接改分发 repo（原 monorepo 源码路径）

## [0.1.0] - 2026-09-21

### Added

- 初始发布：CGC-2046 平台的 OMP 接入包
- `cgc` 主 agent（入口协议 + 纪律，角色方法论来自网站 playbook 动态拉取）
- 连接 onboarding skill（relay 自动连接为主，手工 token 回退）
- `/cgc` 斜杠命令（下一步引导 + 状态汇总 + `/cgc help` 命令参考）
- 确认守门（OMP 原生审批配置，`confirm_operation` 弹审批框，headless 子代理直接拒绝）
- 安装脚本（install.sh，zip 托管 fallback）

### Security

- token 只落 `~/.omp/agent/mcp.json`（0600 权限），不进对话、日志、其他文件
- 确认流安全强度不弱于 OpenClacky 宿主（有 UI 时必经原生审批框，headless 更强）
- 签发后页面渲染 token 明文，任何 page text dump 都会带进会话记录——签发后只能点复制按钮
- 验证连接只看 MCP 握手/工具调用结果，禁止 read mcp.json

### Changed

- README 安装指引：marketplace 主路径（`/marketplace add` + `/marketplace install`）+ zip fallback
- `/cgc help` 命令参考：「你说什么」→「会发生什么」，技术细节折叠弱化

### Fixed

- `/cgc` 卡住问题：`deliverAs: followUp` 空闲挂起 → `nextTurn + triggerTurn: true` 立即起 turn
- 撤销精度：撤销按钮需按卡片名称精确定位，不能只按按钮文本找
- 重复 install 抹 token：merge_mcp_json 保留已有 headers
