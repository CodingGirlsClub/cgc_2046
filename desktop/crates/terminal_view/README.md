# cgc-terminal-view

终端视图：`TerminalView`（GPUI `Entity`，持有一个 PTY 会话）+ `TerminalElement`
（`Element` 实现，按 `Frame` 自绘）。

## 职责边界

- `cgc-terminal`：VT 状态、PTY、渲染帧（`Frame`）、按键编码。
- 本 crate：字体度量、背景/文字/光标绘制、焦点与键盘事件。
- `cgc-desktop-app`：宿主（agent panel 的 ＋ 菜单、pane、持久化）。

`TerminalView::poll` 由宿主驱动（当前是 33ms 定时器）；它负责排空 PTY、
刷新 `Frame`，并在有变化时 `cx.notify()`。

## 绘制

- cell 宽度由 `TextSystem::ch_width` 决定，行高 = `font_size * 1.4`。
- 每个 cell 的文本、颜色、粗体/斜体/下划线/删除线、反色都来自 `Frame`。
- 宽字符占两列：首格绘制完整 grapheme，尾格跳过。
- 连续同色/同字重的 cell 合并成一个 `TextRun`，减少 shaping 次数。
- 光标按 `FrameCursor` 画成 block（后续补 bar/underline 与闪烁）。
- **整帧必须画在 `window.with_content_mask(Some(ContentMask { bounds }), ...)` 里**：
  缺了它 quad 能画、glyph 却完全不出现。
- 背景色取宿主主题（`palette.canvas`），前景取 `palette.ink`，光标取 `palette.accent`。
- ANSI 0–15、默认前景/背景/光标由 `TerminalView::apply_theme` 交给 libghostty：
  创建终端时注入一次，应用切主题时再注入并重绘。libghostty 会按新调色板
  重新解析已显示的 cell，所以历史输出也会换色，shell 进程与滚动位置不受影响。
- 16–255（色立方与灰阶）保持标准值；程序用 SGR 指定的 RGB 颜色原样保留。

## 键盘

`key_from_str` 把 GPUI 的按键名映射成 `libghostty_vt::key::Key`，
`KeyInput::encode` 依据终端当前模式（应用光标键、Kitty keyboard protocol）
编码成字节写入 PTY。未知键返回 `Unidentified`，由编码器决定是否输出。

- `Cmd+V`：按终端当前模式编码粘贴（`TerminalCore::encode_paste`）——
  DECSET 2004 开启时用 `ESC[200~`/`ESC[201~` 包裹，换行安全；
  未开启时换行会变成回车、**每行立即执行**，因此 `paste::is_safe` 判定
  内容可执行命令时先显示确认条，再按一次 `Cmd+V` 才真正写入。
  两种模式都会过滤可注入命令的控制字节
- `Cmd+C`：复制当前选区
- `Cmd+F`：打开搜索条（真输入框，支持 IME）。
  `Enter` 下一个、`Shift+Enter` 上一个、`Esc` 关闭并清空选区。
  所有匹配在视口内高亮（警告色半透明），当前匹配同时被选中；选区和光标
  会覆盖高亮色。

## 鼠标与选择

- 拖拽：从按下点开始按 cell 建立选区，hover 时实时更新。
- 双击：选中单词（`SelectWordOptions`）。
- 三击：选中整行（`SelectLineOptions`）。
- 滚轮：`ScrollViewport::Delta` 回看 scrollback；在 alternate screen
  （`vim` / `less`）里转成方向键发给程序，单次事件最多 10 个按键。
- 链接：`Cmd+单击` 打开 OSC 8 链接；没有 OSC 8 时识别输出里的 URL 或文件路径
  （`src/main.rs:42:5` 这类，点击前会去掉 `:行:列`）。相对路径需要终端的 cwd
  （OSC 7 上报），否则不打开。链接优先于鼠标上报与选区。
- 滚动条：右侧 10px 轨道 + 6px 拇指，长度按可见/总行数比例；点击轨道按位置
  跳转（`ScrollViewport::Row`）。内容不足一屏时不显示。

**鼠标上报**：终端程序开启 DECSET 1000/1002/1003（格式 1006 = SGR）后，
`cgc_terminal::MouseInput` 会把左键按下/释放、拖动与滚轮编码成 xterm 序列
写回 PTY，程序内（`htop`、`vim`、`less`）可直接用鼠标。
按住 `Shift` 强制走本地选区与本地 scrollback，这是终端惯例的覆盖方式。

## 终端事件

`TerminalCore` 通过 libghostty 的 effect 回调收集 `Title` / `Pwd` / `Bell`：

- `Title`：显示在 agent panel 的 header（程序没设标题时回退 `Terminal`）。
- `Pwd`：关闭终端时记住，下次打开从该目录启动；目录已被删除时退回默认位置。
- `Bell`：终端顶部显示「终端响铃 · 按任意键清除」，保持到用户下一次真实按键
  （纯修饰键不算）；未接系统通知。
- 进程退出后，终端下方显示一行退出提示。

## 已知缺口（后续 milestone）

- IME：提交文本已接入，组合中的预编辑（marked）文本尚未回显
- 光标闪烁、Hollow 描边
- 事件驱动重绘（当前 33ms 轮询）
