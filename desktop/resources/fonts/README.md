# 内置字体

| 文件 | 家族名 | 用途 | 许可 |
| ---- | ------ | ---- | ---- |
| `GeistMono-Variable.ttf` | Geist Mono | 终端正文（等宽） | OFL-1.1（`OFL-Geist.txt`） |
| `SymbolsNerdFont-Regular.ttf` | Symbols Nerd Font | 终端图标 fallback（Nerd Font symbols-only） | MIT（`LICENSE-SymbolsNerdFont.txt`） |

两份字体由 `crates/app/src/fonts.rs` 通过 `include_bytes!` 编译进 binary，启动时用
`TextSystem::add_fonts` 注册；终端字体的 fallback 链是
`Symbols Nerd Font → Apple Color Emoji → Apple Symbols`。

## 关于体积

`SymbolsNerdFont-Regular.ttf` 为 2.4 MB，是 Nerd Font 的完整图标集：10627 个字形，
覆盖 U+E000–F8FF 与 U+F0001–F1AF0 等私有区段。

子集化实测（`fontTools.subset`）：保留全部图标码位后仍有 2.3 MB（约 -9%）；按某个
agent 实际用到的图标裁剪虽然能继续缩小，但 OMP / Codex / Claude Code 等程序使用的
图标集合未知且会随版本变化，裁剪会造成图标缺字形（显示为 `?` 或豆腐块）。因此保留
完整集，不为 10% 的体积收益牺牲兼容性。
