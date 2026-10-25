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
