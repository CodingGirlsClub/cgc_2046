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

## native 模型 Provider

设置窗口的 AI Provider 列表可分别添加 OpenAI Compatible 和 Anthropic Compatible。旧配置默认使用 OpenAI 协议，已有 Provider 的协议不可切换。

- Anthropic 的 API URL 填 API 根地址，可包含网关路径前缀或 `/v1`，客户端补全 Messages 路径并使用 `x-api-key` 鉴权。
- 手动填写模型 ID，并配置 Context Window、Max Output Tokens、工具和图片能力。Anthropic 保存 Key 时只写入本机钥匙串，首次对话时由服务端验证，不调用模型发现或额外验证接口。
- 模型支持 thinking 时可选 Budget 或 Adaptive。Budget 必须满足 `1024 <= budget < Max Output Tokens`，保存时校验；Adaptive 使用模型配置的 effort 档位。对话输入区可随时选择 Off，Budget 模型也有开关。
- thinking 请求按模型声明下发：Budget 发送 `enabled` + `budget_tokens`，Adaptive 发送 `adaptive` 与 `effort`。Adaptive 的 Off 与标题、摘要、子 agent 请求一样省略 `thinking` 字段（这些模型可能拒绝 `disabled`，省略即模型默认）；Budget 与关闭 thinking 的模型在 Off 时显式发送 `disabled`。仅显式关闭 thinking 的请求才会携带 temperature。
- Messages 请求不自动跟随 HTTP 重定向：`x-api-key` 不会因网关的 `3xx` 被转发到另一个源，重定向直接作为请求失败报告。
- 模型行的能力声明可带 `efforts=low,high` 尾巴声明该模型接受的 effort 档位；未声明即不下发 `output_format.effort`。设置页保存会原样保留声明，不再由 Adaptive 推断档位。
- 签名 thinking、redacted thinking 与工具块按原始顺序保存。续轮和重开会话只回放前缀仍有效的签名；修改 system、tools、历史或压缩边界后排除旧推理块，保留原始记录。带签名的工具续轮保持前缀不变，超过上下文上限时明确报错。

CLI `cgc-agent-demo` 复用同一协议：设置 `CGC_AGENT_PROTOCOL=anthropic_compatible`，并提供 `CGC_AGENT_BASE_URL`、`CGC_AGENT_API_KEY`、`CGC_AGENT_MODEL`。`CGC_AGENT_THINKING` 可为 `off`、`adaptive` 或整数预算，默认 `off`。

## native 面板结构（Stage 3 Phase B）

- `crates/app/src/native_agent_view/mod.rs` 是模块根（类型 + 结构体 + `mod` 声明，约 411 行）；
  渲染/输入/会话/运行时拆到同目录 12 个子模块（`panel`、`composer`、`rows`、`turn`、`panels`、
  `session`、`input`、`runtime_ops`、`render`、`widgets`、`state`、`tests`）。
  子模块可访问父模块私有字段，未放宽可见性。
- Native 与 external ACP 的输入区共用 `agent_ui::message_editor::MessageEditor`，统一状态创建、4～8 行自动增高、可换行 placeholder 和 inline token 回调；卡片留白与发送按钮尺寸由共享 composer 管理。每个会话保留独立草稿和发送/审批/queue/steer 处理。`CGC_NATIVE_SHARED_VIEW` 已移除。
- External ACP 的用量环、模型／推理配置和发送／停止按钮共用右侧控件组，窄面板换行后仍靠右。费用沿用 agent 上报的币种，非零且小于 `0.01` 时显示 4 位小数，其余显示 2 位。
- `native_thread_state.rs` 已删除，状态类型在 `native_agent_view::state`，对外重新导出为
  `native_agent_view::NativeThreadState`。

## native 请求与长会话（2026-10-27）

- `agent_core::context` 先选择连续、完整的用户 turn，再物化 provider messages；tool-call batch 与结果不会被预算拆开，旧的残缺 batch 整组排除。
- 普通请求、摘要与摘要失败后的裁剪共用装配出口，保留 `reasoning_effort` 并明确设置输出预留。
- 预算包含 system、工具 schema、历史、输出和协议开销；中文采用 UTF-8 保守估计。实际 usage 只修正已有上下文，新注入内容单独计入；图片成本标记为未知，不承诺硬 token 上界。
- 固定输入超限返回 `ContextTooLarge`，不发送已知超限请求，不截短最新输入或附件；原始 transcript 保留。
- `Compaction.covered_until` 是原始 entry 的 exclusive prefix boundary。请求只使用最新有效摘要和未覆盖尾部；旧记录缺覆盖字段时不推测覆盖范围。摘要按完整 turn 有界分块。

## 页面上下文与会话恢复

Native 与 external ACP 共用页面上下文提交逻辑：每轮携带 active tab 的页面、工作台和课程标识；正文按会话、agent、工作台和内容版本去重。排队与重试保留提交时的页面快照，实际发送前重新核对历史；回滚、恢复、压缩或发送失败只失效对应会话。chip 的“已在上下文中”来自本次确实附带正文的发送记录，旧历史世代的记录不能反写。

Native 每次新建对话分配独立 ID，保留旧历史与 checkpoint。scope 的当前线程指针单独存于 `threads.db`，重启后恢复当前选择（包括尚未发送消息的空对话）；旧 `native-<scope>` ID 保持原值兼容恢复。切换模型保留当前对话。ACP 的稳定身份继续使用实际 session ID 和 agent ID，模型、工具、授权与审批仍由对应运行时负责。

Native 的文件操作集中在“变更 N”打开的面板中：N 是相对本轮快照的变更文件数；没有变更时不显示入口。消息上的“回退到此消息之前”回退会话，并恢复可用的文件快照，不自动重新生成回答。纯聊天与空文件快照可正常回退；真实文件恢复失败时保留会话、历史草稿及编辑内容。操作失败只显示一条可关闭的本地提示，新操作会替换旧提示，不向聊天记录反复追加 system 消息。

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

## External ACP agent 的安装与启动

Codex / Claude Code 使用客户端托管的 Node 24 LTS，当前安全下限为 `24.22.0`。Node 放在
`<data_root>/node24`，固定版本 npm 包放在 `<data_root>/agents/<agent-id>/<version>`，
重装 Node 会保留已安装的 agent 包。开发环境可用 `CGC_MANAGED_NODE` 指定 Node 根目录，
agent 包仍放在该根目录同级的 `agents` 目录。

安装器按目标版本目录持有文件锁，在锁内复查已安装包；并发安装会复用先完成的健康包。
需要安装时，先在独立临时目录安装并验证真实版本，再替换目标目录；已有包运行失败时会重新安装。
探测和启动直接使用持久包的入口，因此清除 npm 缓存后仍可启动。托管 Node 的可执行目录会
加入子进程 PATH，并保留标准 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` 及小写形式。
ACP Host 保留启动环境与工作目录；正常 EOF 会结束连接，stdout 关闭后未完成的写入有独立退出期限。
命令超时同时涵盖进程退出与 stdout/stderr 排空；后代进程继续持有管道也不会无限延长等待。

本机探测和回归验证：

```bash
cargo run --locked -p cgc-platform --example agent_detect
cargo test --locked -p cgc-platform --test managed_agent_runtime --test managed_agent_recovery --test managed_agent_install
```

Unix 回归使用系统 `curl`、`/usr/bin/python3` 和本机受控代理，不访问真实 npm registry。


## 单实例与深链

打包后的客户端只允许一个实例；第二次启动会把 URL/参数交给已运行实例并聚焦原窗口。
`cgc://` 深链支持：

```text
cgc://home
cgc://workspace                    # /：上次工作区概览，没有记录则「我的学习」
cgc://workspace/<slug>             # 指定工作区概览
cgc://workspace/<slug>/events/<uuid>
cgc://workspace/<slug>/courses/<uuid>/learn
cgc://settings
cgc://agents
cgc://events                       # 公开活动目录（跨工作区）
cgc://events/<uuid>                # 公开活动详情
cgc://events/mine                  # 兼容：重定向到「我的报名」(/participations)
cgc://courses                      # 公开课程目录（跨工作区）
cgc://courses/<uuid>               # 公开课程详情
cgc://courses/<uuid>/learn         # 站点级学习页（无工作区也可达）
```

未登录时先保存 pending link，登录成功后继续跳转；非法链接回到上次工作区。
`cgc://companion` 已移除：Agent 面板是 dock，不是页面。
`cgc` scheme 由安装包注册；开发时直接以 argv 传入，例如
`cargo run -p cgc-desktop-app -- 'cgc://settings'`。

## 工作区导航

- Site Tree 支持搜索课程、活动标题及已加载的章节和 issue 标题；匹配子项时保留课程与章节，清空搜索恢复原展开状态。搜索词随工作区保存，恢复后主动加载所需列表。
- 课程树仅在本人报名状态为 `confirmed` 时加载和展开学习正文；未报名、审批中、待支付及已取消的课程保留详情入口并显示解锁提示。报名状态覆盖已加载的全部分页，报名成功后同步更新。
- 「我的学习」「我的报名」按条目所属工作区显示名称并跳转；没有归属信息或没有工作区访问权时使用站点级页面。跨工作区打开学习页或 issue，会在目标工作区恢复标签后插入并保存新标签。
- 公开目录的基础查询不读取受成员权限保护的归属字段。课程详情优先读取本人报名或学习投影的归属；可访问工作区的课程归属通过既有权限查询按页批量补齐，成员未报名时也可进入所属工作区。来源名称无法从可见工作区列表解析时隐藏徽标，不显示内部 ID。

自动化回归覆盖完整 `RootView` 输入焦点、切台与标签恢复，以及 HTTP 字段权限和报名归属。UI 测试使用 `CGC_UI_TESTS=1 cargo test -p cgc-desktop-app --features gpui-kit/test-support --lib -- --test-threads=1`，课程 HTTP 端到端测试使用 `cargo test -p cgc-courses --test public_course_e2e`。

## 托盘与系统通知

- 启动后常驻系统托盘：左键打开/聚焦主窗口，右键菜单提供打开、设置、退出。
- 主窗口关闭默认留在托盘（可在 Settings 的「窗口行为」关闭）；应用退出走托盘「退出」。
- `preferences.json` 保存 `closeToTray`、首次关闭提示状态，以及 Settings →「通用」的
  `cursorBlink`（`blinking` / `steady` 光标闪烁）。
- 图标覆盖是内部/调试能力（不进 Settings，也不写进 `preferences.json`）：设置
  `CGC_ICON_OVERLAY_DIR=<目录>` 启动时预读与 Kit 图标同名的普通 SVG，缺失或不符合下述文件边界时继续使用内置图标；
  符号链接、目录和 FIFO 不参与加载，单文件不超过 256 KiB、覆盖快照合计不超过 16 MiB。
  覆盖字节与解析路径在启动时固定，绘制不再访问覆盖目录，修改文件后需重启；不设置时完全使用内置图标。
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

## 设置与面板布局

设置窗口（`⌘,` / 托盘「设置」）分六页：账号、通用、`Window & Layout`、`Panels`、AI、关于。

- `Window & Layout`：标题栏的品牌名/面包屑/通知按钮显隐；状态栏四个面板按钮显隐；关闭窗口时留在托盘。
- `Panels`：每个面板一组，含 Dock Position（左/右）、默认宽度、新工作台默认展开（仅 Dock）、显示未报名课程。
- 状态栏图标右键提供 `Dock Left` / `Dock Right` / `Hide Button`；图标随面板停靠侧移到左组或右组。
- 面板宽度、开合与右侧当前面板按 workspace 记忆（`workspace_state.json`），优先于设置默认值；通知面板不记忆。
- `新工作台默认展开` 与默认宽度作用于尚未自定义布局的 workspace；手动切换面板或拖动宽度后，按 workspace 保留布局覆盖。
- `Panels → 当前工作台 → 重置当前工作台布局`：二次确认后清除当前 workspace 的布局覆盖并套用当前 `Panels` 默认值；保留标签、当前页面、站点树筛选与滚动位置，其他 workspace 不变。重置后继续跟随默认值，直到再次手动调整布局。
- 重置按钮支持 `Tab` / `Shift-Tab` 聚焦，`Enter` / `Space` 激活；首次激活只进入确认状态。
- 已知限制：debug 构建下，若 macOS 辅助功能被激活（例如自动化工具读取界面），点击「面板 → 默认宽度」的 `+`/`−` 会触发 `gpui-pre 0.3.11` 的 a11y 断言（`set_focus called more than once in a single frame`）并 panic；release 构建只记录 warn。移除条件：`gpui-kit` / `gpui-pre` 升级修复后删除此条。

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
cargo packager -p cgc-desktop-app --release -f dmg     # macOS（单架构）；Windows 用 -f wix，Linux 用 -f deb,appimage
# macOS universal（发版用）见下节「内测分发（无证书）」
bash scripts/name-artifacts.sh                          # 重命名为 cgc2046_<version>_<commit>_<platform>-<arch>.*
bash scripts/verify-package.sh                          # hdiutil / dpkg-deb / AppImage 结构校验
bash scripts/smoke-package-runtime.sh                   # macOS：从 dmg 启动 release 二进制并确认存活
CGC_DESKTOP_TOKEN=<jwt> bash scripts/verify-m0-backend.sh  # 真实后端 M0 冒烟（工作台/场次/课程/投影）
bash scripts/verify-package.sh                          # Windows: pwsh scripts/verify-package.ps1
```

- 产物未签名：证书暂无（ADR-0027 决策 2/3），签名、公证与自动更新归 epic-6（`epic-distribution-integration`）。
- macOS 产物为 **universal（arm64 + x86_64）**：CI 交叉编译两个架构再 `lipo -create`，Intel 机器不用另选包；本地单架构仍可直接 `cargo packager`。

## 内测分发（无证书）

内测包由用户双击 `.app` 启动，**拿不到 shell 环境变量**，所以后端端点与运行环境必须编进二进制。
macOS 产物是 **universal**（arm64 + x86_64），Intel 机器不用另选包：

```bash
cd desktop
rustup target add x86_64-apple-darwin
CGC_DEFAULT_API_URL=https://api.codingirlsclub.com/api/graphql \
CGC_DEFAULT_ENV=prod \
  cargo build --release -p cgc-desktop-app --target aarch64-apple-darwin
CGC_DEFAULT_API_URL=https://api.codingirlsclub.com/api/graphql \
CGC_DEFAULT_ENV=prod \
  cargo build --release -p cgc-desktop-app --target x86_64-apple-darwin
mkdir -p target/universal-apple-darwin/release
lipo -create -output target/universal-apple-darwin/release/cgc-desktop-app \
  target/aarch64-apple-darwin/release/cgc-desktop-app \
  target/x86_64-apple-darwin/release/cgc-desktop-app
CGC_ARTIFACT_ARCH=universal \
  cargo packager -p cgc-desktop-app --release --target universal-apple-darwin -f dmg
```

- `cargo-packager` 不做 lipo，所以先合并再打包：`--target universal-apple-darwin` 的
  binaries 目录正好是 `target/universal-apple-darwin/release/`。
- `CGC_ARTIFACT_ARCH=universal` 让 `scripts/name-artifacts.sh` 产出 `_macos-universal` 后缀，
  并让 `scripts/verify-package.sh` 用 `lipo -archs` 断言两个 slice 都在（fail-closed）。
- 发布走 tag：打 `desktop-v<base>[-dev.<YYYYMMDD>.<n>]` 触发 `.github/workflows/desktop-release.yml`，
  三平台产物 + `SHA256SUMS` 挂到 GitHub Release（`--prerelease`，未签名不对外）。

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

## 发布节奏（内测）

桌面客户端的内测版是 **tag 驱动**的，不走 `develop → main` 的 Web/后端发布流程：

1. 确认 develop 的 CI 全绿（`desktop` required check 覆盖三平台构建与测试）。
2. 生成并推送 tag。发布 job 会断言 **tag 的 base 版本与 `desktop/Cargo.toml` 一致**、
   **tag 是合法 semver（允许 `-dev.…` 后缀）**、**tag 提交已在 develop/main 上**。

   内测 tag 带日期与当天序号（`desktop-v<base>-dev.<YYYYMMDD>.<n>`），**不需要改 Cargo.toml**：
   一天发多次时序号自动递增。`Cargo.toml` 的 `version` 只承载 base 版本，在功能里程碑时人工 bump
   （它的注释写明 macOS 的 `CFBundleShortVersionString` 只接受数字点分，所以 dev 后缀只能放在 tag 上）。

   ```bash
   git fetch origin develop --tags
   tag=$(bash scripts/next-dev-tag.sh)          # 例如 desktop-v0.1.0-dev.20261103.1
   git tag -a "$tag" origin/develop -m "CGC-2046 桌面客户端内测（未签名）"
   git push origin "$tag"
   ```

   第一次发某个 base 的正式内测版时，也可以直接打 `desktop-v0.1.0`（无 `-dev` 后缀），
   两者都走同一条流水线，区别只在版本号与产物名。

3. `Desktop Release` 自动执行：**生产 schema 兼容门禁**（`desktop/scripts/check_release_schema.py`：
   用完整 document 探测生产端点，缺任一字段即 fail-closed 拒绝构建）
   → 三平台构建 → 产物校验（universal 包用 `lipo -archs` 断言双架构）
   → 生成 `SHA256SUMS` → 建 **prerelease**（未签名，只作内测通道）。

   **产物形态**（内测期统一「免安装」）：

   | 平台 | 产物 | 说明 |
   |---|---|---|
   | macOS | `cgc2046-macos-universal.dmg` | Intel + Apple Silicon 同一包（安装器注册 `cgc://`） |
   | Windows | `cgc2046-windows-x64.zip` | 便携包，解压即用；**深链需手动注册**（见下） |
   | Linux | `cgc2046-linux-x64.tar.gz` | 便携包，解压即用；**深链需手动注册**（见下） |

   > 便携包不经过安装器，而 `cgc://` 协议注册原本由安装器完成（`crates/app/Cargo.toml` 的
   > `deepLinkProtocols`）。要用「网页点链接跳回客户端」，解压后跑一次随包的注册脚本：
   > Windows `powershell -ExecutionPolicy Bypass -File register-protocol.ps1`（写 HKCU，免管理员）；
   > Linux `bash usr/bin/register-protocol.sh`（写 `~/.local/share/applications` + `xdg-mime`，免 root）。
   > 不跑也能正常使用，只是 `cgc://` 深链打不开。

   **文件名不带版本**（版本由 tag 承载）。每个产物配一个同名 `.build.json`，字段：

   | 字段 | 含义 |
   |---|---|
   | `schemaVersion` | 元数据格式版本，当前 `1` |
   | `product` | 固定 `cgc2046` |
   | `version` | 完整版本，含 dev 后缀（如 `0.1.0-dev.20261103.1`） |
   | `releaseTag` | 构建用的 git tag |
   | `sourceRevision` | 完整 commit SHA |
   | `platform` / `arch` | `macos|windows|linux` / `universal|x64|aarch64` |
   | `signing` / `notarized` | 内测期固定 `unsigned` / `false` |

   要确认「这个包是哪次构建」就查它——`verify-package.sh` 也是读它做断言，不再解析文件名。

4. 抽查产物（下载后实跑校验，别只看日志）：

   ```bash
   curl -LO <release>/cgc2046-macos-universal.dmg
   curl -LO <release>/cgc2046-macos-universal.build.json
   shasum -a 256 -c SHA256SUMS
   cat cgc2046-macos-universal.build.json      # 版本 / commit / 签名状态
   hdiutil attach -nobrowse -readonly cgc2046-macos-universal.dmg
   lipo -archs /Volumes/程序媛汇/程序媛汇.app/Contents/MacOS/*
   ```

5. 内测同学从 Release 页下载；macOS 浏览器下载需 `xattr -dr com.apple.quarantine`（`curl` 下载不带 quarantine）。

修发布问题时：先合入 develop，再 `git tag -f` + `git push -f origin <tag>` 重跑——
tag 指向旧提交会带着旧 bug 构建。撤销一次发布：`gh release delete <tag> --yes --cleanup-tag`。

CI 分工：PR 阶段 desktop 只跑 lint + 测试（快）；**打包在合并后（push）和 tag 时**跑，
所以「打包配置坏了」最晚会在 develop push 或下一次 tag 时暴露。

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
- **平台工具凭证恢复**：Native 与 ACP 共用按账号和 API 服务端隔离的钥匙串凭证。冷启动通过 `GET /mcp/token` 核实归属、类型和 token ID 后复用；旧版 `learning_host` 明文项核实后迁移，额度已满也可恢复。401 才按失效处理；网络错误／429／5xx 保留凭证且不增发。新凭证保存失败会撤销本次签发，登出只撤销本机记录，不批量撤销其他客户端。授权失败在 Tab 栏下方独立提示，`Retry` 重新尝试恢复，长诊断不再挤掉标签；文案按失败类别分流（后台不可达 / 凭据不可用 / 凭据额度满），GraphQL 与 MCP 授权失败同时落 `app.log`（operation + 端点 + 错误类别，不含凭证）；工作台列表拉取失败时概览页与切换器都给出失败态与重试入口（#1238）。
- **授权回归验证**：凭证测试在 `crates/platform/src/mcp/credential/tests.rs`；真实 TabBar 测试在 `crates/app/src/root_view/screens/workspace/pane/tests.rs`。UI 测试默认不编译：需 `CGC_UI_TESTS=1`（`crates/app/build.rs` 打开 `cfg(cgc_ui_tests)`）并启用 Kit 的 `test-support`——`CGC_UI_TESTS=1 cargo test -p cgc-desktop-app --features gpui-kit/test-support --lib -- --test-threads=1 authorization_failure_and_long_notices`。该 feature 会把 `gpui-fast` 系拉进解析图，而 `gpui-fast 0.1.13` 对 `taffy` 精确 pin `=0.15.0`、`gpui-fast-web 0.1.13` 对 `unicode-properties` 精确 pin `=0.1.3`（`gpui-pre 0.3.11` 是 `^0.15.0` / `^0.1.3`，允许）。因此 `Cargo.lock` 把这两个包固定在 `0.15.0` / `0.1.3`：**不要 `cargo update` 它们**，回到补丁新版后该 feature 会解析失败。移除条件：`gpui-kit` 松开这两个 pin。CI 的 desktop-build 在 macOS 腿已跑这一步（Linux/Windows 的 headless 窗口未验证，暂不铺开）；`scripts/check_licenses.py` 以同一 feature 取 metadata，测试依赖也进许可门禁与 SBOM。写 UI 测试时**不要在子模块里 `use super::*`**：`root_view` 本身 glob 导入 `gpui_kit::*`，叠加后 `#[gpui_kit::test]` 的属性宏展开会递归，rustc 直接 SIGBUS（实测）；只导入用到的名字。
- **侧栏状态**：历史侧栏开关会写入 `preferences.json`（`historySidebarOpen`），重启后恢复。
- **全局 Agent Panel（3.5a）**：任意页面打开同一 Agent Panel / 同一线程；课程学习页自动把 course/revision/unit 作为上下文附加到每条 prompt（native/ACP 同一段文本，输入气泡不显示），上下文 chip 可移除。不再有课程页专用工作区/会话指针。
- **默认 agent（3.5b，2026-10-27）**：新会话（含课程页）默认 native；`CGC_NATIVE_AGENT=0` 或设置「使用 Native Agent 运行时」关闭时回退 External Agent（external 仍可在 `＋` 菜单选择）。
- **Native 图片粘贴**：共享编辑器通过 Kit `Textarea::on_paste` 在默认文本插入前接收图片与复制的图片文件；快捷键和菜单粘贴共用该入口，普通输入不读取剪贴板。附件粘贴保留正文、token、多光标、选区方向与文本撤销历史；带描述文字的剪贴板不会因包含图片文件名而被吞掉。真实 composer 回归在 `crates/app/src/native_agent_view/paste_tests.rs`（沿用上文 test-support 的锁文件 pin 与 `CGC_UI_TESTS=1`，测试过滤器 `paste_tests`）。
- **Agent Header 无障碍名称**：Native/External 共用的实际新对话按钮提供中英文名称；真实 Header 回归在 `crates/app/src/root_view/screens/chat/editor_tests.rs`。
- **全局 active tab 上下文**：所有中心内容 tab（课程 issue/整页、场次详情/列表、课程详情/目录、学习/参与列表、工作台概览）在 native/ACP 输入文字流中显示当前页附件 chip。草稿中的自动 chip 跟随当前 Tab，保留问题文字和手动附件；删除 chip 后本条消息不再附加当前页。发送时固定来源和正文快照，排队／重试不随之后的 Tab 改变。正文按线程 + Agent + tab 内容版本去重；chip 显示「待引用／已引用／待更新」，保留加载中、无正文、失败及部分引用状态，自动跟随与发送规则放在 tooltip。已引用页面的追问只带页面身份，不重复正文或通用提示；历史恢复或压缩后保守重载。Native 插话在收到实际消费回执后才标记已引用。
- **Selection 与历史编辑**：`＋ → Selection` 将中心页面选中文字及其来源保存为独立附件；课程卡目标、清单及 Markdown 正文支持选择。Native 编辑历史消息时恢复原 chip 位置和快照，可替换为当前页再回滚重发；external ACP 的 `Edit copy` 将原消息及附件恢复到 Composer，作为新一轮发送。页面／Selection／File／Skill 快照随会话保存，重新打开历史后仍可恢复。

## 共享视图（Stage 3.6 Phase B，2026-10-26）

- **共享层**：native 与 external ACP 共用 `ConversationThread` + `ThreadCapabilities` + `agent_ui` 消息行/审批卡/composer 组件；能力位（`checkpoint_restore/steer/queue/subagent/config_options/plan/usage/attachments/images`）决定入口显隐。
- **shared composer（灰度）**：`CGC_NATIVE_SHARED_VIEW=1` 时 native 主 composer 使用共享渲染（textarea + 附件 chips + slash/mention/context/queue addon + 模型/thinking/审批 picker + queue/steer/send/stop）；缺省/`0` 走 legacy composer。flag 为临时灰度开关，B4b 删除旧视图后移除。
- **B3 能力**：模型 / thinking / 审批模式 picker 为 native-only 且 capability gated（ACP 用自己的 config options picker）；checkpoint 变更列表/全部保留/全部回退/单文件 Keep-Restore 已抽为共享面板 helper（数据层复用 `agent_checkpoint`）；subagent 进度行迁到 `agent_ui::subagent_row`，native 与共享视图共用、行顺序由 `message_row_kinds` 决定。
- **B4a 迁移**：native 面板非 UI 逻辑已抽到 `app/src/native_context.rs`（workspace prompt/slash/mention）、`attachment.rs`（图片编解码/预览）、`native_session.rs`（thread/checkpoint 持久化）、`native_panel_host.rs`（agent_state/ACP host/title/audit/model 选择）；controller 创建 native 面板时经 host 注入。
- **已知限制**：`native_agent_view.rs`（约 5850 行）尚未删除（B4b 等两轨真机验收后进行）；`CGC_NATIVE_SHARED_VIEW` flag 仍在；默认 native 已覆盖课程页（3.5b），但 MCP 工具只在有 `learning_host` lease 时注入（3.4d 真机待验）。
- **本地门禁口径（开发）**：本机 Rockxy/Clash 代理会污染 localhost mock，全量测试固定清代理并串行：`env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY -u http_proxy -u https_proxy -u all_proxy -u no_proxy cargo test --workspace --exclude cgc-agent-tools -- --test-threads=1`（本轮实测 596 passed / 0 failed）。UI 测试另跑一条（见上文「授权回归验证」，必须串行：用例共享进程级全局，并行时 `native_composer_uses_shared_editor_growth` 会在 `expect("runtime snapshot")` 处超时）：`CGC_UI_TESTS=1 cargo test -p cgc-desktop-app --features gpui-kit/test-support --lib -- --test-threads=1`。
