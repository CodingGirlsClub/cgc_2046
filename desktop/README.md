# 程序媛汇 Desktop

学员端原生桌面客户端（GPUI + gpui-kit，Rust）。组织方式对齐 Zed：**每个子系统一个 crate
平铺在 `crates/` 下，`app` 是唯一 binary crate（组合根）**。架构与不变量见
`_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（脊柱 AD-1 至 AD-24）
与 `docs/adr/0024-0027`。

## 用户设置文件（`settings.json`）

对齐 Zed 的 `settings.json`：GUI 不管理的参数放这里，手改后下一次请求即时生效，无需重启。

```json
{
  "agent": {
    "thread_summary_model": { "provider": "deepseek", "model": "deepseek-flash" },
    "model_parameters": [
      { "provider": "deepseek", "model": "deepseek-flash", "temperature": 0.2 }
    ]
  }
}
```

- 位置（与 Zed 的 per-OS 配置目录一致）：
  - macOS：`~/.cgc2046/settings.json`
  - Linux：`$XDG_CONFIG_HOME/cgc2046/settings.json`（默认 `~/.config/cgc2046/settings.json`）
  - Windows：`%APPDATA%\cgc2046\settings.json`
  - 测试/QA 可用 `CGC_SETTINGS_FILE` 覆盖整个路径。
- `thread_summary_model`：Thread Title 使用的独立模型（`provider` + `model`）；未配置、模型禁用、
  provider 没存 key 时回退当前对话模型。设置页不再提供该配置。
- `model_parameters`：`provider` / `model` 均可省略；**从后往前**第一条匹配生效，命中条目即使
  `temperature` 为 `null` 也不再继续向前找（与 Zed `AgentSettings::temperature_for_model` 一致）。
  温度作用于 native agent 的普通 turn 与 thread title 请求；未配置时不下发，保持模型默认采样。
- 文件缺失 = 默认设置；JSON 非法会打印诊断并回退默认，不阻塞启动。当前只支持标准 JSON（不支持注释）。

## native 面板结构（Stage 3 Phase B）

- `crates/app/src/native_agent_view/mod.rs` 是模块根（类型 + 结构体 + `mod` 声明，约 411 行）；
  渲染/输入/会话/运行时拆到同目录 12 个子模块（`panel`、`composer`、`rows`、`turn`、`panels`、
  `session`、`input`、`runtime_ops`、`render`、`widgets`、`state`、`tests`）。
  子模块可访问父模块私有字段，未放宽可见性。
- `CGC_NATIVE_SHARED_VIEW` 已移除；composer 只有一条渲染路径。
- `native_thread_state.rs` 已删除，状态类型在 `native_agent_view::state`，对外重新导出为
  `native_agent_view::NativeThreadState`。

## native 请求与长会话（2026-10-27）

- `agent_core::context` 先选择连续、完整的用户 turn，再物化 provider messages；tool-call batch 与结果不会被预算拆开，旧的残缺 batch 整组排除。
- 普通请求、摘要与摘要失败后的裁剪共用装配出口，保留 `reasoning_effort` 并明确设置输出预留。
- 预算包含 system、工具 schema、历史、输出和协议开销；中文采用 UTF-8 保守估计。实际 usage 只修正已有上下文，新注入内容单独计入；图片成本标记为未知，不承诺硬 token 上界。
- 固定输入超限返回 `ContextTooLarge`，不发送已知超限请求，不截短最新输入或附件；原始 transcript 保留。
- `Compaction.covered_until` 是原始 entry 的 exclusive prefix boundary。请求只使用最新有效摘要和未覆盖尾部；旧记录缺覆盖字段时不推测覆盖范围。摘要按完整 turn 有界分块。

## 本机前置

- Rust **1.98+**（`rust-toolchain.toml` 锁 1.98.1；本机可用已安装的更新版本，如 `RUSTUP_TOOLCHAIN=stable`）
- macOS 15+ / Windows 10+（MSVC + CMake 在 PATH）/ Ubuntu 24.04（Wayland 或 X11 会话 + Vulkan 驱动）
- Linux 额外依赖见 gpui-kit 安装文档；登录凭证需要 `libsecret-tools`（Debian/Ubuntu: `sudo apt install libsecret-tools`）

## 运行

```bash
cd desktop
cargo run -p cgc-desktop-app     # 打开主窗口（默认落在 home，header 含一级导航）
cargo test --workspace           # 路由注册表与各 crate 单测
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
```

默认连真实后端（`http://localhost:4000/api/graphql`，可用 `CGC_API_URL` 或
`~/.cgc2046/settings.json` 的 `api.url` 覆盖）；只有显式
`CGC_AUTH=fake` 才使用本地假数据（无后端跑 UI 或单测）。界面不暴露演示账号，发布形态
不依赖任何演示数据。

`CGC_LANG=zh|en` 选择启动语言（默认 zh），`CGC_THEME=light|dark|system` 覆盖主题，
`CGC_LOG=error|warn|info|debug|trace` 调日志级别（默认 info，文件见「内测分发」）。

## 单实例与深链

打包后的客户端只允许一个实例；第二次启动会把 URL/参数交给已运行实例并聚焦原窗口。
`cgc://` 深链支持：

```text
cgc://home
cgc://workspace
cgc://settings
cgc://agents
cgc://companion
cgc://events
cgc://events/<uuid>
cgc://events/mine
cgc://courses
cgc://courses/<uuid>
cgc://courses/<uuid>/learn
```

未登录时先保存 pending link，登录成功后继续跳转；非法链接回到工作台。
`cgc` scheme 由安装包注册；开发时直接以 argv 传入，例如
`cargo run -p cgc-desktop-app -- 'cgc://settings'`。

## 托盘与系统通知

- 启动后常驻系统托盘：左键打开/聚焦主窗口，右键菜单提供打开、设置、退出。
- 主窗口关闭默认留在托盘（可在 Settings 的「窗口行为」关闭）；应用退出走托盘「退出」。
- `preferences.json` 保存 `closeToTray` 与首次关闭提示状态。
- 登录后每 60 秒拉取 `notificationFeed`，未读通知通过系统通知中心展示；点击通知走
  `cgc://` 路由并调用 `markNotificationRead`。
- `notifications.json` 保存最近已展示通知的 id 与目标路由，避免重启后重复弹。
- macOS 系统通知要求从 `.app` 启动；`cargo run` 的未打包进程不会弹通知（GPUI 保护）。
- Linux 托盘使用 StatusNotifierItem；桌面没有托盘 host 时托盘不可见，但应用仍可运行。

## 通知中心

- 顶部头像左侧的铃铛显示未读数角标（`9+` 封顶）。
- 点击铃铛打开右侧通知中心；与 Site Tree / Outline 共用右侧 Dock，可拖宽。
- 列表来自 `notificationFeed`，支持全部/未读筛选、刷新、分页加载和重试。
- 点击通知会标记已读、关闭对应系统通知，并走 `cgc://` 深链跳转；未知路径回工作台。
- 新通知优先按后端 `targetType/targetId` 跳转：活动 → 活动详情，课程 → 课程页，报名 →
  我的报名，工作台 → 工作台；旧通知回退原有 `deepLink`。
- 通知时间按系统本地时区展示，解析失败时退回 UTC 截断格式。
- 托盘菜单的 `通知` 也会打开通知中心；主窗口已关闭时会先恢复窗口。
- 当前不做「全部已读」，因为后端只有单条 `markNotificationRead`。

## 审批规则（toolPermissions，native-only）

设置级审批规则（Stage 3.2b，路线 A / Zed 对齐）**只作用于 native agent**，保存在
`preferences.json`（与 `closeToTray` 同文件；MVP 暂无设置 GUI，手改文件后**下一次
审批即时生效**）：

```json
{
  "toolPermissions": {
    "default": "ask",
    "tools": {
      "run_command": {
        "alwaysAllow": ["^ls"],
        "alwaysDeny": ["rm -rf"],
        "alwaysConfirm": ["git push"]
      }
    }
  }
}
```

- `default`：`ask`（默认，弹共享权限卡）/ `allow` / `deny` / `confirm`。
- `tools.<toolName>`：对**精确工具名**生效（native 工具如 `run_command` /
  `write_file` / `read_file`）；每个字段是正则列表，匹配对象 = **工具名或参数
  JSON 文本**（`echo` 这类命令子串可直接命中）；非法正则忽略该条并在 stderr 记录
  warning，不影响其他规则。
- 优先级：`deny > allow > confirm > default(ask)`；同一 kind 命中任一规则即生效。
- 命中 `allow` / `deny` 时不弹审批卡，直接回传对应选项，并在会话里留一条 system
  提示（如「已按设置自动允许 run_command」）；`confirm` 强制弹卡（即使
  `default=allow`）；无匹配规则或请求里没有对应类选项时回退弹共享权限卡。
- native 的 Auto 模式同样不叠加规则（Auto 由 runtime 内部 `AutoApprover` 放行）。

**external ACP agent 不适用本规则**：omp / codex 等外部 agent 的审批完全由它自己的
模式与 options 决定——客户端只渲染 agent 提供的共享审批卡、按用户点击的
`option_id` 原样回传，不做策略拦截、也不会自动 allow/deny。若 agent 在自己的模式里
自动批准（例如 codex 的 `auto` 模式），客户端根本收不到 `session/request_permission`；
要让 external agent 询问审批，需在 **agent 自己的配置里切到 ask/default 模式**。

## 目录与依赖方向（脊柱 AD-1）

```text
crates/
  app/          入口、窗口、导航壳、路由聚合（唯一 binary crate / 组合根）
  account/      登录注册、工作台、设置
  events/       场次、报名、支付、核销码
  courses/      课程目录、学习页、正文渲染
  agent_chat/   学习搭子对话、agent 选择
  platform/     端口 trait（api / session / agent / registry / update / telemetry）
  platform-macos/   macOS 的 OS 适配器（通知/深链/单实例/托盘/keychain/进程）
  platform-windows/ Windows 的 OS 适配器
  platform-linux/   Linux 的 OS 适配器
```

`app → 各 domain crate → platform`，`platform-{macos,windows,linux} → platform`；禁止 `platform → platform-*`，
禁止 domain crate 之间互相依赖。加功能的默认落点是已有 domain crate 的 module；
只有「独立依赖面 / 被两个以上 crate 复用 / 需要并行隔离或独立发布」之一才新建 crate。
CI 在 1.13 建立后由依赖边界检查兜底。

## CI 与打包（story 1.13）

- CI：`.github/workflows/ci.yml` 的 `desktop` job，三平台 matrix（`macos-15` / `windows-2022` / `ubuntu-24.04`），跑 `fmt` / `clippy -D warnings` / `test` / release build / cargo-packager。
- 打包格式：macOS `dmg`，Windows `wix`（产物 `.msi`），Linux `deb,appimage`；产物在 `desktop/dist/`。
- 本地复现：

```bash
cd desktop
cargo install cargo-packager --locked --version =0.11.8
cargo packager -p cgc-desktop-app --release -f dmg     # macOS；Windows 用 -f wix，Linux 用 -f deb,appimage
bash scripts/name-artifacts.sh                          # 重命名为 cgc2046_<version>_<commit>_<arch>.*
bash scripts/verify-package.sh                          # hdiutil / dpkg-deb / AppImage 结构校验
bash scripts/smoke-package-runtime.sh                   # macOS：从 dmg 启动 release 二进制并确认存活
CGC_DESKTOP_TOKEN=<jwt> bash scripts/verify-m0-backend.sh  # 真实后端 M0 冒烟（工作台/场次/课程/投影）
bash scripts/verify-package.sh                          # Windows: pwsh scripts/verify-package.ps1
```

- 产物未签名：证书暂无（ADR-0027 决策 2/3），签名、公证与自动更新归 epic-6（`epic-distribution-integration`）。
- macOS 产物为 runner 原生架构（arm64）；x86_64 与 universal 留给 epic-6/7。

## 内测分发（无证书）

内测包由用户双击 `.app` 启动，**拿不到 shell 环境变量**，所以后端端点与运行环境必须编进二进制：

```bash
cd desktop
CGC_DEFAULT_API_URL=https://api.codingirlsclub.com/api/graphql \
CGC_DEFAULT_ENV=prod \
  cargo packager -p cgc-desktop-app --release -f dmg
```

- `CGC_DEFAULT_API_URL` / `CGC_DEFAULT_ENV` 由 `crates/platform/build.rs` 登记，进
  `runtime::api_endpoint()` 与 `paths::AppPaths::from_env()`；不注入时行为不变（本机端点 + dev 数据根）。
- 官方域是 **`codingirlsclub.com`**（`api.codingirlsclub.com` 是后端；`codinggirlsclub.com`
  不是我们的服务域，历史上拼错过一次导致内测包登录全挂）。`scripts/verify-package.sh` /
  `verify-package.ps1` 对产物做 fail-closed 断言：二进制必须含官方端点、不得含错拼域。
- 解析顺序：`CGC_API_URL` 环境变量 > `~/.cgc2046/settings.json` 的 `api.url` > 编译期默认值。
  给测试同学切后端只改这一行，不用重打包：

  ```json
  { "api": { "url": "https://api.codingirlsclub.com/api/graphql" } }
  ```

- **端点白名单**（`runtime::is_allowed_endpoint`）：`https://` 只接受 `codingirlsclub.com`
  及其子域，`http://` 只接受 `localhost` / `127.0.0.1` / `[::1]`；不在名单里的候选被忽略并
  回落下一个来源，最后退到本机开发端点。Bearer token、登录密码、下单请求与 MCP lease token
  都走这条通道，所以是 fail-closed。
- 日志：`<data_root>/logs/app.log`（prod 为 `~/Library/Application Support/cgc-desktop/logs/app.log`），
  5 MB 轮转保留一份历史；级别用 `CGC_LOG=error|warn|info|debug|trace`（默认 `info`）。
  写入前统一过 `telemetry::redact_sensitive`（token/手机号/邮箱不进日志），panic 也落到同一文件。
- 未签名包的 Gatekeeper 绕过与下载方式见发布说明（建议 `curl -L -o` 下载后拖入 `/Applications`，
  curl 不写 quarantine 属性；浏览器下载则需 `xattr -dr com.apple.quarantine`）。

## 设计与文案基座（stories 1.2–1.4）

- **主题 token**：`crates/app/src/theme.rs` 把 `web/app/globals.css` 的色板 / 圆角 / 字体映射成常量（Dark 来自 `:root`，Light 来自 `.light`），并把这些值写进 gpui-kit `Theme`（组件库也用同一套色板）；间距用 web 实际使用的 Tailwind 默认 4px 刻度（`globals.css` 没有导出 spacing token）。偏好 `Light | Dark | System`，系统外观变化由 `observe_window_appearance` 触发重刷；启动可用 `CGC_THEME=light|dark|system` 指定（QA/调试，默认 `system`）。
- **i18n**：真源是 `desktop/resources/i18n/keys.txt`（必需 key 清单）+ `{zh,en}.lang` 词表，key 规则 `feature.domain.key`。`crates/app/build.rs` 构建期校验：每个登记 key 在两个 locale 都存在、词表没有未登记 key、无重复/非法命名/空值；缺 key 直接构建失败并指出 key 与 locale，并生成强类型 `Key`（代码不能引用未登记 key，双表同删会编译失败）。启动语言用 `CGC_LANG=zh|en`（默认 `zh`）。
- **注册 seam**：每个 domain crate 的 `src/registration.rs` 声明 `ROUTES` 与 `I18N_KEYS`；app 启动时聚合（`registration::build_registry` / `validate`）并拒绝重复 `Route.id`/path、动态段 `:`（v1 未支持）、domain 间重复 key、route 标题 key 重复与缺词条。对应单测直接调生产校验函数（不是测试内复刻），冲突会在 CI 变红并给出具体 id/path/key/两个 owner。
- **字体**：Inter / Geist Mono 是 web 的目标字体，桌面端暂未随包（缺失时由 gpui 回退系统字体）；随包字体留到后续 story。


## Agent 历史与 MCP 状态（Stage 3，2026-10-26）

- **唯一入口=桌面**：Web 端 agent 与 `cgc-host` 已删除；桌面客户端（native CGC Agent + external ACP agents）是唯一 agent 入口。
- **统一历史**：native 与 external ACP agent 共用历史侧栏（footer 时钟图标 / Agent Panel `⋯` → Toggle Threads Sidebar / `⌥⌘J`）；Rename（写 `title_override`）、Archive/Unarchive、今天/昨天/最近 7 天/更早分桶、过滤；ACP 每 agent 最近 5 条自动归档。
- **ACP transcript 本地库**：`<data_root>/conversations.db`（0600、WAL，`thread_content` + `sidebar_threads`；另有 `native_archived` 表存 native 归档标记）。打开历史先显示本地记录，`session/load` 成功则回放替换，失败显示「外部 agent 无法恢复会话，以下为本地记录」。
- **永久清空**：Settings → AI →「清空 ACP 对话历史」（二次确认，仅 ACP；native 不受影响）。Archive 只隐藏，不删除。
- **审批规则**：`preferences.json` 的 `toolPermissions` **仅 native 生效**（详见上文「审批规则」）；external agent 的审批由 agent 自身模式决定。
- **MCP（3.4a/b/c，2026-10-27）**：native MCP client 已落地 Streamable HTTP JSON-RPC（initialize/tools/list/tools/call，Bearer/SSE/超时/401/403 fail-closed，token 不进日志）。native-only 注入 5 个只读课程工具：`mcp:cgc-2046-learning:{get_course_content,get_course_revision,get_learning_state,get_role_playbook,get_enrollment_summary}`；白名单外不注册，无 lease/token 时 0 注册（fail-closed）。配置与 ACP 注入同源（`learning_host` lease + `mcp_endpoint(CGC_API_URL)`）；`CGC_MCP_ENDPOINT`/`CGC_MCP_TOKEN` 仅作 headless 测试 seam。**3.4d 真机待验**（真实平台 MCP server 的 tools/list 与工具调用）。
- **侧栏状态**：历史侧栏开关会写入 `preferences.json`（`historySidebarOpen`），重启后恢复。
- **全局 Agent Panel（3.5a）**：任意页面打开同一 Agent Panel / 同一线程；课程学习页自动把 course/revision/unit 作为上下文附加到每条 prompt（native/ACP 同一段文本，输入气泡不显示），上下文 chip 可移除。不再有课程页专用工作区/会话指针。
- **默认 agent（3.5b，2026-10-27）**：新会话（含课程页）默认 native；`CGC_NATIVE_AGENT=0` 或设置「启用 Native Agent 入口」关闭时回退 External Agent（external 仍可在 `＋` 菜单选择）。

## 共享视图（Stage 3.6 Phase B，2026-10-26）

- **共享层**：native 与 external ACP 共用 `ConversationThread` + `ThreadCapabilities` + `agent_ui` 消息行/审批卡/composer 组件；能力位（`checkpoint_restore/steer/queue/subagent/config_options/plan/usage/attachments/images`）决定入口显隐。
- **shared composer（灰度）**：`CGC_NATIVE_SHARED_VIEW=1` 时 native 主 composer 使用共享渲染（textarea + 附件 chips + slash/mention/context/queue addon + 模型/thinking/审批 picker + queue/steer/send/stop）；缺省/`0` 走 legacy composer。flag 为临时灰度开关，B4b 删除旧视图后移除。
- **B3 能力**：模型 / thinking / 审批模式 picker 为 native-only 且 capability gated（ACP 用自己的 config options picker）；checkpoint 变更列表/全部保留/全部回退/单文件 Keep-Restore 已抽为共享面板 helper（数据层复用 `agent_checkpoint`）；subagent 进度行迁到 `agent_ui::subagent_row`，native 与共享视图共用、行顺序由 `message_row_kinds` 决定。
- **B4a 迁移**：native 面板非 UI 逻辑已抽到 `app/src/native_context.rs`（workspace prompt/slash/mention）、`attachment.rs`（图片编解码/预览）、`native_session.rs`（thread/checkpoint 持久化）、`native_panel_host.rs`（agent_state/ACP host/title/audit/model 选择）；controller 创建 native 面板时经 host 注入。
- **已知限制**：`native_agent_view.rs`（约 5850 行）尚未删除（B4b 等两轨真机验收后进行）；`CGC_NATIVE_SHARED_VIEW` flag 仍在；默认 native 已覆盖课程页（3.5b），但 MCP 工具只在有 `learning_host` lease 时注入（3.4d 真机待验）。
- **本地门禁口径（开发）**：本机 Rockxy/Clash 代理会污染 localhost mock，全量测试固定清代理并串行：`env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY -u http_proxy -u https_proxy -u all_proxy -u no_proxy cargo test --workspace --exclude cgc-agent-tools -- --test-threads=1`（本轮实测 596 passed / 0 failed）。
