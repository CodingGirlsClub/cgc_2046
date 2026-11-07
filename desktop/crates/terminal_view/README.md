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
- 背景色取宿主主题（`palette.canvas`），前景取 `palette.ink`，光标取 `palette.accent`；
  ANSI 调色板仍来自 libghostty-vt，浅色主题下的 ANSI 色对比度待映射（见缺口）。

## 键盘

`key_from_str` 把 GPUI 的按键名映射成 `libghostty_vt::key::Key`，
`KeyInput::encode` 依据终端当前模式（应用光标键、Kitty keyboard protocol）
编码成字节写入 PTY。未知键返回 `Unidentified`，由编码器决定是否输出。

## 已知缺口（后续 milestone）

- 鼠标选择/滚动、拖拽选中、Cmd+C 复制
- IME：提交文本已接入，组合中的预编辑（marked）文本尚未回显
- 滚动条与回看
- bracketed paste（当前 Cmd+V 直接写字节，未经 `paste` API 的安全包装）
- ANSI 调色板映射到应用主题（浅色主题下黄/绿对比度偏低）
- 光标闪烁、Hollow 描边
- 事件驱动重绘（当前 33ms 轮询）
