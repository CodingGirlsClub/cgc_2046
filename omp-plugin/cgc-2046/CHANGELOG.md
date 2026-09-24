# Changelog

All notable changes to the CGC-2046 OMP plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `cgc-quality-eval` skill：质检报告判据化评审（`submit_prep_quality_report` 前置）。三层架构——确定性 grep 终判格式类判据、judge_batch 两段式 triage 语义项（嫌疑清单待人裁）、教材原文配对终判书外声明（noul 逐声明）。score/summary 为判据聚合产物，summary 禁止自由发挥。无 judge 模型时降级为 L1 + 嫌疑清单。真机验证：某已发布 43 卡课程 ground truth 对照，教材配对终判 8/8 全中（两个已知书外实锤全部捞出，置信 0.98+），锚点格式 grep 判据 100% 精准（见 docs/quality-eval-validation-2026-09-22.md）
- `docs/quality-criteria-proposal.md`：tutor playbook 质检章判据化提案（卡级 8 + 课程级 6 判据、评分权重、summary 聚合纪律），提 backend 侧 playbook 修订

## [0.1.5] - 2026-09-22

### Added

- `/cgc` 版本检查：读本地安装版本与 catalog 缓存版本，不一致时 notify 提示「有新版本可用：X（当前 Y）。跑 omp plugin upgrade 更新」

## [0.1.4] - 2026-09-21

### Changed

- `/cgc` 工作目录引导：检测不在 `~/cgc2046_workspace` 时，用 `ask` 引导用户「创建并切换」vs「就在当前目录工作」vs「取消」（原仅显示被动提醒）。选「创建并切换」：创建目录并教退出重启，不渲染汇总；选「就在当前目录工作」：继续渲染汇总；选「取消」：不做任何操作。`ask` 抛错（headless）降级按「创建并切换」默认。

## [0.1.3] - 2026-09-21

### Changed

- 路径迁移：`omp-ext/cgc-2046/` → `omp-plugin/cgc-2046/`（形态已是 Plugin，不是裸 Extension）
- 全部引用更新：sync workflow `paths:` 过滤、install.sh、install.test.sh、README、plan 文档、interim catalog、CI workflow 名

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
