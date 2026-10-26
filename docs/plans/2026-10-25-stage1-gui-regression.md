# Stage 1 真机 GUI 回归（2026-10-25）

> 范围：Stage 1 共享化改动（`agent_ui` 的 message_flow / message_actions /
> markdown_view+safe_markdown / markdown_text / message_row / picker / command_menu）在
> native 面板与 ACP 面板的真实渲染回归。
> 代码基线：`feat/native-agent-design @ ce056302`（工作树干净），debug 构建。
> 环境：macOS 27.2（Darwin arm64），GPUI + gpui-kit 0.8.0。
> 方法：隔离 HOME（`/tmp/cgc-stage1-regression`）+ `.app` wrapper 让 LaunchServices 可绑定，
> `CGC_NATIVE_AGENT_DEMO=1` 打开 native 面板；用 CUA 读取 AX 树 + 截图 + 系统剪贴板取证。
> 测试数据：native 离线 EchoProvider（空 prefs）与人工种子 Fake Provider（12 个模型，
> 前 3 个支持 thinking，selected=fake-8）；均为隔离数据目录，不含真实凭证。

## 结论

**未发现共享化引入的回归**；native 侧操作栏/复制/picker/slash 菜单全部按预期工作。
有 2 类事项需要人工补测：**picker 滚轮滚动**（CUA 滚轮在非激活窗口未生效）与 **整条 ACP 链路**
（隔离实例无平台登录与外部 agent，未读取用户真实凭证）。无阻塞缺陷。

## 结果清单

| # | 检查项 | 结果 | 证据 |
|---|---|---|---|
| N1 | 消息操作栏只在回合末出现 | PASS | 两回合各一组按钮；AX：第一组 `Copy This Agent Response` / `Scroll to User Message`，第二组再加 `Scroll to Top`（见 02） |
| N2 | `Scroll to Top` 仅线程底部 | PASS | 第一回合操作栏无 Top、第二回合（底部）有 Top（AX 元素 4/5 vs 8/9/10，见 02） |
| N3 | Copy This Agent Response = 整回合、按回合隔离 | PASS | 点第一回合 Copy → 剪贴板 `（离线 demo）收到：hi`；点第二回合 Copy → `（离线 demo）收到：second turn`，互不包含（Echo 模式，每回合单条回复） |
| N4 | assistant 行渲染/间距 | PASS | 截图 01/02：Markdown 正文、右侧 muted 操作栏、40% 透明 + hover 区一致 |
| N5 | 消息操作栏 hover 提亮 | PARTIAL | 静态截图图标为 muted 态；CUA 无 hover 注入，需人工鼠标确认 |
| N6 | 模型 picker（分组/选中/选择回调） | PASS | 打开后 AX 列出 `Fake Provider` 组与 fake-1..fake-12；截图 03 中 fake-8 accent + ✓；点 fake-5 → 触发器变 `fake-5`；再选 fake-1 → 触发器 `fake-1` |
| N7 | 推理强度 picker（含 Off） | PASS | fake-1 支持 thinking 时出现触发器 `low`；打开后 AX：low/high/Off；选 high → 触发器 `high`（见 04） |
| N8 | 审批模式 picker（Ask/Auto） | PASS | 打开后 AX：`Ask（逐次审批）`/`Auto（自动允许）`；选 Auto → 触发器 `Auto`；已恢复 Ask |
| N9 | picker 列表滚动 | PARTIAL | 12 项列表被 max-height 正确裁剪（约 10 项可见），AX 暴露全部 12 项；CUA 页滚轮在非激活窗口没有可见位移，需人工滚轮确认 |
| N10 | slash 命令菜单（分组/选中/detail/点击） | PASS | 输入 `/` 后左侧分组列表（命令 6 项 + 工具 10 项）、`/help` 选中带 soft 背景/accent 文本、右侧 detail 显示 `/help` 与描述；点击 `read_file` → 输入框变为 `使用 read_file 工具：` 且菜单关闭（见 05） |
| N11 | streaming 时历史操作栏仍可见 / 底部条隐藏 | NOT COVERED | EchoProvider 即时返回，CUA 抓不到可靠的 streaming 帧；需真实慢模型人工确认 |
| N12 | thinking chevron 行渲染 | NOT COVERED | 测试模型不产生 thinking 内容；需真实可产生 reasoning 的 provider |
| N13 | 末尾停在工具卡时的兜底操作栏 | NOT COVERED | 测试环境无工具调用（Echo 不调用工具，Fake Provider 不可达） |
| N14 | 等审批时底部条隐藏 | NOT COVERED | 无工具审批触发；需 ACP/native 真实审批流 |
| A1 | ACP 面板：操作栏/复制/整回合语义 | BLOCKED | 隔离 HOME 无平台登录、无外部 ACP agent；不读取用户真实凭证 |
| A2 | ACP 面板：config picker 搜索/滚动条 | BLOCKED | 同上 |
| A3 | ACP 面板：Markdown 代码块 Copy（新增能力） | BLOCKED | 同上 |
| A4 | ACP 面板：消息区滚动三按钮（`track_scroll` 修复） | BLOCKED | 同上 |
| N15 | 消息区滚动三按钮点击效果 | NOT COVERED | 两回合短消息无需滚动；仅验证了按钮出现位置。需长线程人工确认 |

## 回归过程中发现的问题与修复（2026-10-25）

**现象**：回归启动的同款 app 被看到「全屏都是 Agent，看不到客户端中间的内容与其他 Panel」。

**原因链**：
1. 真机回归用的是隔离 demo 实例（`CGC_NATIVE_AGENT_DEMO=1`），启动时会额外打开 Native Agent 窗口；
   该窗口 `WindowOptions.window_bounds = None` 会继承主窗口 bounds，尺寸接近全屏、盖住主窗口。
2. 隔离 HOME 下主窗口停在登录页，没有客户端内容与面板，所以视觉上只剩 Agent。
3. `cx.set_app_identity("com.codinggirlsclub.cgc2046.desktop", "程序媛汇")` 硬编码：demo 实例与
   正式客户端同 identity/display name，macOS Dock 与应用切换可能把测试实例当作正式 app，
   进一步造成「客户端不见了」的错觉。

**修复**（`crates/app/src/main.rs`）：
- `CGC_NATIVE_AGENT_DEMO=1` 时改用独立 identity/display name：`...desktop.demo` / `程序媛汇（demo）`；
- demo Agent 窗口显式 `WindowBounds::Windowed(1000×760)`、标题 `CGC Agent（demo）`，不再继承主窗口 bounds；
- 正式实例行为不变。

**验证**：编译与门禁通过；窗口尺寸/标题改为代码显式指定。测试实例已停止、隔离目录（含临时 wrapper 与
截图）已删除，不再在 LaunchServices 里留下测试 app。

## 复现方式

```bash
ROOT=/tmp/cgc-stage1-regression
mkdir -p "$ROOT/home" "$ROOT/workspace"
# 可选的种子 prefs：12 个假模型（用于 picker/滚动回归），写入
#   "$ROOT/home/Library/Application Support/cgc-desktop-dev/agent_prefs.json"
# 构建并启动（用一个最小 .app wrapper 以便 LaunchServices/辅助功能能绑定）：
cargo build -p cgc-desktop-app
HOME="$ROOT/home" CGC_NATIVE_AGENT_DEMO=1 CGC_AGENT_WORKSPACE="$ROOT/workspace" \
  /path/to/worktree/desktop/target/debug/cgc-desktop-app
```

> 注意：demo 模式现在使用独立 app identity/display name（`程序媛汇（demo）`），Agent 窗口固定
> 1000×760 且标题为 `CGC Agent（demo）`，不会与正式客户端实例混淆。

ACP 回归需在用户正常实例（已登录 + 已安装外部 agent）或复制测试账号会话后进行；本轮未做，
以免读取真实凭证。

## 2d 离线真机回归（2026-10-25，native 切共享模型后）

环境：HEAD `a05e9997` 构建，隔离 HOME + demo `.app` wrapper（`CGC_NATIVE_AGENT_DEMO=1`），
EchoProvider 离线模式；未使用真实 provider/keychain。

| 检查项 | 结果 | 证据 |
|---|---|---|
| 窗口身份/尺寸 | PASS | 窗口标题 `CGC Agent（demo）`、1000×760，与正式实例 identity 隔离 |
| 发送 + 回合末操作栏 | PASS | AX：编辑消息/恢复检查点/Copy/Scroll to User/Scroll to Top；截图 2d-01 |
| Copy This Agent Response | PASS | 剪贴板 `（离线 demo）收到：hello` |
| 单回合底部 Scroll to Top | PASS | 唯一回合（底部）出现 Top |
| slash 菜单 | PASS | AX 列出命令 6 项 + 工具 10 项；截图 2d-02 |
| 审批 picker | PASS | AX：Ask（逐次审批）/Auto（自动允许） |
| `/clear` | PASS | 发送后消息行与操作栏全部消失，仅剩 composer；截图 2d-03 |
| 编辑消息入口 | PARTIAL | 按钮存在，CUA 点击未打开编辑态（可能需 hover 后点击），需人工确认 |
| 工具卡/审批条/checkpoint/subagent/thinking | BLOCKED | EchoProvider 不产生工具调用，需真实 provider 实例（人工） |

未发现 2d 收尾引入的渲染崩溃或操作栏回归；Permission 行与审批条是否重复仍需真实
工具审批场景确认。

## 残余风险

1. ACP 面板（含 Stage 0 修的滚动三按钮、1c 新增的代码块 Copy）尚未真机验证，建议合并前人工跑一次。
2. picker 滚轮滚动未验证；若真实滚轮也不生效，需要检查共享 `picker` 的 `overflow_y_scroll` 容器。
3. 共享样式统一后的视觉差异（操作栏默认透明度、assistant 行间距、slash 菜单 description 列）
   在本轮截图中目测一致，但未与旧版并排截图对比。

## 取证截图

- `01-native-single-turn.jpeg`：单回合操作栏（Copy/ScrollUser/Top 底部）
- `02-native-two-turns-actions.jpeg`：两回合；第一回合无 Top、第二回合有 Top
- `03-model-picker.jpeg`：模型 picker 分组 + 选中 fake-8（accent + ✓）
- `04-thinking-picker.jpeg`：推理强度 low/high/Off
- `05-slash-menu.jpeg`：slash 菜单分组 + 选中 `/help` + 右侧 detail

## 2e composer 真机回归（2026-10-25，部分完成）

环境：隔离 HOME + `preferences.json{ nativeAgentEnabled:true }` + `CGC_NATIVE_AGENT=1`
+ `CGC_AUTH=fake` 假登录；构建自 `e24b0ce1`。

| 检查项 | 结果 | 证据 |
|---|---|---|
| native composer 卡片/footer/发送按钮渲染 | PASS | 输入框、Ask、echo、发送按钮正常；单窗口布局（左 Agent/中内容/右目录） |
| 发送 + 回合末操作栏 | PASS | 编辑消息/恢复检查点/Copy/Scroll to User/Scroll to Top |
| 真实 provider 工具/审批/checkpoint | BLOCKED | 隔离 HOME 下 keychain 不可用→EchoProvider；真实 HOME 假登录时课程页恢复 ACP(omp)，MCP lease 不可用 |
| ACP 全链路 | BLOCKED | 需真实登录 + 外部 agent |

未发现 2e composer 重构引入的渲染回归；功能段（工具/审批）需人工切到 native 模式跑一次。

## 2e composer 真实 provider 回归（2026-10-25，PASS）

环境：真实 HOME（keychain 可用）+ 独立 `CGC_DATA_DIR`（不碰真实 data/prefs）+
`nativeAgentEnabled=true` + 空 chat_state + `CGC_AUTH=fake` 假登录 + `CGC_NATIVE_AGENT=1`；
真实 DeepSeek（`deepseek-flash`），构建自 `912e4f8d`。

| 检查项 | 结果 | 证据 |
|---|---|---|
| native composer（共享 card/footer/发送按钮） | PASS | 输入框/Ask/deepseek-flash/low/发送；生成中切换为红色 Stop |
| 真实工具卡 | PASS | `run_command` 显示 参数 JSON、输出（等待→完成）、状态「运行中…」 |
| 审批卡 | PASS | 允许一次/本会话允许/前缀允许/拒绝；只有一个审批卡 |
| 审批重复行（2d 修复验证） | PASS | 截图仅一条「等待审批：允许运行 run_command？」 |
| 回合末操作栏 + Copy | PASS | 编辑/恢复检查点/Copy/ScrollToUser/Top；剪贴板为本回合完整回复（含 stdout `hi`） |
| 停止按钮 | PASS | 生成中显示停止（红），完成后恢复发送 |

**已知小问题**：审批卡最右侧「拒绝」文字在窄布局下被裁切，需要在审批行按钮布局上收一下宽度
（不影响操作，可点击区域仍在）。

## ACP 真机回归（2026-10-25，BLOCKED）

尝试路径：本地 Phoenix 后端（`localhost:4000`，新建开发库 + seeds + 测试账号
`demo@example.com/demo1234`）+ App 隔离 `CGC_DATA_DIR`/`CGC_SESSION_FILE` +
`CGC_API_URL` 指向本地后端。

已验证：
- 本地后端 health 200；后端 GraphQL `listCourses`（含 workspace scope）返回演示课程；
- 课程已通过 Ash `:create` + SQL status=open 出现在 App 课程页（截图确认「ACP 回归课程」）；
- App 确实请求本地后端（后端日志可见 graphql/listCourses/myEnrollment 调用）。

阻塞点：
1. CUA 对 GPUI 自定义课程列表的坐标点击无法打开课程详情（普通/双击/不同坐标系均未触发）；
   AX 树不暴露课程列表项，无法用元素索引点击；
2. 课程详情内的 ACP 会话还需要学习上下文/MCP lease；当前 App 左侧 Agent 面板仍显示
   「学习上下文不可用（workspace/课程版本缺失）」。

结论：ACP 真机回归需要人工点击课程详情（或安装正式 App 后从课程页进入）后执行；
自动化在当前 CUA/GPUI 组合下无法进入课程详情。清单见 Stage 1 报告的 A1–A4。

## ACP 真机回归（2026-10-25 深夜，进展 + BLOCKED）

### 已打通

用「真实 HOME（Host 已配对、omp 已装、keychain 可用）+ 隔离 `CGC_DATA_DIR`
（含课程配置）+ 隔离 `CGC_SESSION_FILE` + 本地 Phoenix 后端」启动 App：

- 本地后端：测试账号 `demo@example.com/demo1234`，课程 `42ac85f2-…` 已报名
  （enrollment confirmed）并绑定 `CourseRevision`（`current_revision_id`）；
- App：课程详情出现「开始学习」，按 Enter 进入学习页，页面显示
  「工作台 75717622… / 课程版本 1 / 学习进度 0/0」——学习上下文 PASS；
- 在隔离 `chat_state.json` 写入 `{课程 id: {"agent": "omp"}}` 后启动 App，
  **`omp acp` 进程成功拉起**（pgrep 实测），说明 ACP 会话链路可以启动。

### 阻塞

设备进入锁屏/睡眠后（约 22:00 起），App 进程虽在，但窗口数 0：
`CUA getApp` 返回 `cgWindowNotFound`，`System Events` 查询窗口数为 0。
多次清数据/换 bundle/重启均复现，与用户睡觉、屏幕锁定时间吻合。
因此无法用 CUA 操作 ACP 面板，composer/config/usage/slash/操作栏与
Copy/滚动清单均未能在真机执行。

### 恢复步骤（解锁 Mac 后）

1. 运行 `/tmp/cgc-acp-live/CGCACP2.app`（wrapper 已含真实 HOME + 隔离
   data2/session + `CGC_API_URL=localhost:4000`；`data2/chat_state.json`
   指针课程→omp）；
2. 登录态沿用；进入「课程」→「ACP 回归课程」→ 开始学习；
3. 等 `omp acp` 进程出现（pgrep），ACP 面板即可操作；
4. 按 Stage 1 报告 A1–A4 清单执行并截图。

## ACP 真机回归（2026-10-26 晨，PASS 主体 / 1 项待补）

设备解锁后继续，环境：真实 HOME（Host 已配对、omp 已装、keychain 可用）+
隔离 `CGC_DATA_DIR`（data2，含 chat_state 指针 课程→agent=omp）+ 隔离 session +
本地 Phoenix 后端（课程 `42ac85f2-…` 已报名、已绑定 revision）。

| 检查项 | 结果 | 证据 |
|---|---|---|
| ACP 会话启动 | PASS | 学习页左侧出现 ACP composer；`omp acp` 进程实测存在 |
| 共享 composer 卡片/footer/发送按钮 | PASS | ACP footer：附件、default、model（deepseek-flash）、auto、usage「1% · 13.9K/1.0M」、发送按钮 |
| 文本回合 | PASS | 发送后收到 omp 回复（含 Thinking 折叠） |
| 生成中停止按钮 | PASS | 生成中变 Stop，点击后恢复「发送」 |
| 整回合 Copy | PASS | 点 Copy 后剪贴板为完整回复文本（已核对） |
| 滚动操作栏 | PASS | Scroll to User Message / Scroll to Top 存在且可点 |
| slash 菜单 | PASS | 输入 `/` 弹出命令面板（omp 命令/skills 列表，100+ 项） |
| config pickers | PASS | agent 配置（default）/ 权限（auto）/ 模型选择 dialog 均可打开 |
| Markdown 代码块 Copy | 待补 | 误切到未配置的 openai-codex 模型导致生成卡住，未完成该项；下次新会话（默认 deepseek）补测 |

说明：误切模型是测试操作副作用，不是 2e 回归；重启新会话即可恢复默认模型。
