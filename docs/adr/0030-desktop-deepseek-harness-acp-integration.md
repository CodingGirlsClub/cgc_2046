---
status: accepted
date: 2026-11-12
---

# ADR-0030：桌面客户端集成 DeepSeek Harness ACP（openma 适配器）

> 日期：2026-11-12 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：ADR-0024（桌面技术栈）、ADR-0026（注册表信任）、ADR-0028（native / external 双轨）、ADR-0029（Agent 调用契约）
> 方案：本地工作稿 `tmp/answers/dsh-acp-plan.md`（P0–P5，不入库）

## 背景（Context）

桌面客户端已有 native agent（默认）与 external ACP agent 双轨（ADR-0028）。external 轨当前只上架 OMP / Codex / Claude Code，缺少 DeepSeek Harness 学习场景。openma 的 `@openma/deepseek-harness-acp` 提供标准 ACP adapter，可在同一协议面提供流式消息、工具调用、审批、plan / usage、session list / load / resume 等能力，直接复用现有 `platform::acp` 事件通道与 `agent_ui` 渲染。

适配器固定 `0.4.41`（2026-11-10 发布），Node `>=22.15`（使用客户端托管的 Node 24）；包内自带 `dsh 0.2.1-rc.5` 私有运行时（`vendor/dsh-runtime.tgz`，约 176 MB），同时也支持使用用户自己安装的 dsh。两种形态共享 `$DSH_HOME`：同一套凭据、设置、profile 与会话数据。

在实现前必须固定四个决策，避免各阶段临时发明语义：运行时从哪来、凭据怎么进、会话数据放哪、缺失 DSH Desktop 时怎么处理。

## 决策（Decision）

### D1 运行时：有 DSH Desktop 时优先 plugin 形态，standalone 回退

两种启动形态：

- **plugin 形态（优先）**：检测到 `dsh` CLI（`DSH_CLI` > PATH > `~/.local/bin/dsh`）且 `$DSH_HOME/profiles/acp/package.json` 已声明 `@openma/deepseek-harness-acp` 时，客户端启动 `dsh --profile acp`。adapter 作为用户 DSH profile 的插件运行，复用其 providers（magpie / GLM / Kimi 等）、凭据 seam、技能与 MCP；模型目录直接来自 DSH composition（实测 85 个模型，默认 `magpie::auto/deepseek-v4.1-flash`）。
- **standalone 回退**：没有 DSH Desktop 或 profile 未安装 adapter 时，使用 adapter 包内 `vendor/dsh-runtime.tgz`（`--dsh-path bundled`），模型选项由 `--models` 决定，默认只有内置 DeepSeek 两家（4 个选项）。

不再把 DSH Desktop 的 `Contents/Resources/runtime/cli/bin/dsh` 传给 `--dsh-path`：openma 无法从 Electron `app.asar` 加载 dsh，实测报 `could not find a usable runtime`。plugin 形态由 DSH 自己的 CLI 启动，不经过 `--dsh-path`。

`RuntimeProbe.source` 取值 `explicit | dsh-desktop | path | bundled | plugin | missing`。plugin 形态下 UI 显示「使用本地 DSH profile acp（adapter {version}）」，并隐藏 standalone 的共享开关（profile 本身位于 `$DSH_HOME`）。

### D2 凭据 env-only：keychain 只注入子进程环境，不落明文

CGC 托管的 DeepSeek Key 以本机 keychain 为唯一真源。启动 ACP 子进程时读取 keychain，只通过**子进程环境变量**注入（`DEEPSEEK_API_KEY`；按 provider 路由可对应 `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`，base URL 走 `DEEPSEEK_BASE_URL` 等已有环境变量），然后把子进程交还给适配器的环境回退路径。

- **不写 `$DSH_HOME/.credentials.yaml`**：适配器的 `authenticate`（`api-key` / `gateway`）会调用 `saveCredential` 把明文持久化到该文件；默认不调用这条路径。P3 的客户端流程是：UI 检测到 `-32000 auth_required` 后引导用户在当前 Provider 设置里保存 Key（只进 OS keychain），再重启 adapter；下一次启动从 keychain 读取并注入 `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL`，不经过 ACP `authenticate`，因此不会产生 `.credentials.yaml`。
- 密钥不进入 settings、日志、遥测、崩溃报告与对话内容；日志沿用现有 `telemetry::redact_sensitive` 脱敏。
- keychain 读取失败或无凭据时不启动带空 key 的进程：按 `-32000 auth_required` 走「登录」入口（P3）。
- **plugin 形态的凭据名映射**：adapter 0.4.41 的 credential gate 按 `<PROVIDER>_API_KEY` 推导名字（例如 `MAGPIE_API_KEY`），与 DSH 自定义 provider 的 `apiKeyEnv`（例如 `MAGPIE_GATEWAY_KEY`）不一致。客户端在 plugin 启动时读取 `$DSH_HOME/.credentials.yaml` 的 `refs`（仅接受 owner-only 可读的文件），把 magpie 的引用值映射成 `MAGPIE_API_KEY` / `MAGPIE_RESPONSES_API_KEY` / `MAGPIE_ANTHROPIC_API_KEY` 注入子进程环境；只在内存中处理，不写盘、不记录值，CGC keychain 已注入的同名值优先。

### D3 会话隔离：默认独立 `DSH_HOME`，可显式共享本地 DSH

客户端为 DSH ACP 集成默认创建**独立的 `DSH_HOME`**（位于客户端数据根下，如 `<data_root>/dsh-home`），不复用用户自己的 `~/.dsh`，也不与 DSH Desktop 的会话/凭据目录混用。

- 学员对话、profile、会话记录只落在该隔离目录，不进入用户自己的 DSH Desktop 数据；多账号 / 多工作台按数据根隔离。
- 目录权限 0700；卸载时删除包与隔离 `DSH_HOME`（P4）。
- 启动 ACP 子进程时显式设置 `DSH_HOME` 覆盖，禁止依赖用户环境中的同名变量。

**opt-in 共享（个人开发场景）**：Agent Registry 的 DeepSeek 条目提供「与本地 DSH 共享会话」开关（`AgentPrefs.dsh_share_local_home`，默认关闭）。仅适用于 standalone 回退；plugin 形态本身要求 profile 位于 `$DSH_HOME`，不存在隔离选项。开启后：

- `DSH_HOME` 指向本地 DSH 数据目录（`DSH_HOME` 环境变量 > `~/.dsh`），adapter 的会话日志与 DSH Desktop/Web 共用同一份，CGC 侧栏仍通过 `session/list` 合并展示；
- 卸载只删 CGC 安装包，**不删除**共享目录；共享目录视为用户数据，由用户自行管理；
- 多账号 / 多工作台不再隔离：同一台机器上各账号会看到彼此的 DSH 会话；UI 必须提示这一点；
- 本地 DSH 版本与 adapter 内置运行时不一致时只警告（当前 0.2.2 vs 0.2.1-rc.5），不阻断，兼容性由用户判断。

### D4 DSH Desktop 缺失不阻断安装/启动

DSH Desktop 不是 standalone 回退的运行时前置：`detect` 在 plugin 探测失败后按适配器安装与版本判定 `Ready`，DSH Desktop 缺失只作为信息提示（`detect` 不返回阻断性的运行时状态）。`registry.json` 的 `deepseek` 条目不再声明 blocking 的 `requires`，`download_hint` 只用于 UI 展示可选下载入口。

standalone 回退的安装、启动和对话始终使用 adapter 自带 bundled dsh；plugin 形态使用用户 DSH 的 runtime。生产构建不因缺少 DSH Desktop 阻断，开发/自测也不需要额外准备。

### 适配器版本与许可

- 锁定 `@openma/deepseek-harness-acp@0.4.41`；Node 24 由客户端托管，不依赖系统 Node。
- 许可证 Apache-2.0，与项目 AGPL-3.0-only 兼容。npm 运行时依赖树（含传递依赖与可选平台包）登记在 `desktop/scripts/npm_licenses.json`，由 `desktop/scripts/check_licenses.py` 与 Cargo 扫描一起做许可门禁。
- 保留上游归属：`desktop/NOTICE` 记录 Apache-2.0 版权与 `src/multi-root/NOTICE.md` 的 MIT 归属；升级适配器版本必须同步更新 `npm_licenses.json` 与 `NOTICE`。

## 否决的替代

- **外部 dsh 直接复用**：DSH Desktop 的 CLI 包装脚本指向 Electron `app.asar`，openma standalone adapter 无法加载；强行 `--dsh-path` 会直接失败，故统一使用 adapter 自带 bundled 运行时。
- **把 DSH Desktop 当硬前置**：会阻断未安装 DSH Desktop 的学员和 CI，且对 standalone adapter 并无实际运行收益；保留检测信息即可。
- **ACP `authenticate` 落盘凭据**：`api-key` / `gateway` 会写 `$DSH_HOME/.credentials.yaml` 明文（0600 仍是明文），违背「凭据不落明文」；env-only 更简单也更安全。
- **共享 `~/.dsh`**：学员对话会与用户自己的 DSH Desktop 数据混在一起，卸载清理也会误删用户数据。

## 后果（Consequences）

**正面**：有 DSH Desktop 时完整复用其模型/provider/技能（实测 85 个模型，含 magpie routing group）；没有 DSH Desktop 时 standalone 回退仍开箱即用；凭据不落盘；会话数据可选隔离（standalone）或共享（plugin 天然共享）。

**代价 / 风险**：plugin 形态强依赖 DSH Desktop 安装与 `dsh` CLI，且 `dsh 0.2.2-rc.3` 比 adapter 测试上限 `0.2.1-rc.5` 新，只警告不阻断；plugin 启动约 2.8s（加载 profile 插件/MCP），并会加载用户 profile 的全部 MCP/技能，外部依赖失败（如 Rockxy 未运行）只打日志；standalone 的运行时版本跟随 adapter 发布，安全修复需等适配器发版；隔离 `DSH_HOME` 会多一份本地数据目录与卸载清理逻辑。

**回滚**：plugin 形态执行 `dsh plugin --profile acp remove @openma/deepseek-harness-acp` 即退回 standalone；standalone 的隔离 `DSH_HOME` 可整体删除，不影响其他 external agent 与 native 轨。

## 落地

- **P0**：本 ADR + license 门禁（`npm_licenses.json` / `check_licenses.py` / `NOTICE`）。
- **P1**：运行时探测（`RuntimeProbe`）、注册表条目（`deepseek`）、安装与启动、`initialize` 自检。
- **P2/P3/P4/P5**：对话与 UI 映射、鉴权与凭据、会话连续性、测试与发布，详见本地工作稿 `tmp/answers/dsh-acp-plan.md`。

## 参考

- 方案文档（本地工作稿）：`tmp/answers/dsh-acp-plan.md`
- 适配器包：<https://www.npmjs.com/package/@openma/deepseek-harness-acp/v/0.4.41>
- 上游仓库：<https://github.com/openma-ai/deepseek-harness-acp>
- 许可规则：`docs/开源合规/依赖引入规则.md`
