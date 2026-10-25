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

ACP 回归需在用户正常实例（已登录 + 已安装外部 agent）或复制测试账号会话后进行；本轮未做，
以免读取真实凭证。

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
