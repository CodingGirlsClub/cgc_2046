# cgc-terminal

终端核心：`libghostty-vt`（VT 解析 / 屏幕状态 / 渲染快照）+ `portable-pty`（进程）。
这一层不依赖 GPUI；渲染与面板集成在 `terminal_view`（M2 起）。

## 为什么是 libghostty-vt

- 覆盖 VT 解析、grid、scrollback、reflow、search、selection，以及 key/mouse/focus/paste 编码；
  不自建终端模拟器。
- C ABI 已到 1.0（`vt-1.0.0`），Rust 绑定仍是 0.x，**升级必须整包验证**。
- 句柄全部 `!Send + !Sync`：本 crate 的类型必须在同一线程创建与使用；PTY 读线程只传字节。

## 构建链（M0 实测）

**依赖 Zig 0.17.1**，且必须用 git rev，不能用 crates.io 的 0.2.2：

| 项 | 结论 |
| --- | --- |
| Zig 0.17.1 | 可用（本机由 mise 管理：`mise use -g zig@0.17.1`） |
| Zig 0.15.2 | **不可用**：当前 pin 的 ghostty 源使用 `@backingInt`（Zig 0.16+ 才有）；旧 pin 在 macOS 27 下链接 build runner 失败（`__availability_version_check` 未定义）。mise 装的是 ziglang.org 官方二进制，与手动下载同一份，结果相同 |
| crates.io `libghostty-vt 0.2.2` | **不可用**：pin 的 ghostty commit `a887df42` 使用 `b.build_root`，Zig 0.17 已移除该字段 |
| git `84373f8d` | 可用：pin 的 ghostty commit `0b8b9984` 改用 `b.root.root_dir.handle`，且需要 Zig 0.16+ |

首次构建时 `libghostty-vt-sys` 会把 ghostty 源码 clone 到 `OUT_DIR`（`--filter=blob:none`），
再跑 `zig build`。需要能访问 `github.com` 与 `deps.files.ghostty.org`；代理网络下 Zig 的
HTTP 客户端不可靠（socks 代理会得到 400），CI 要保证直连或预取。

CI（`.github/workflows/ci.yml` 的 `desktop-build`、`desktop-release.yml` 的 `build`）
由「安装 Zig 0.17.1」步骤下载官方 tarball 到 `$RUNNER_TEMP/zig`，再用 job 级 `ZIG`
环境变量把路径交给 build.rs；本地不设 `ZIG` 时回落到 PATH 里的 `zig`。

加快重复构建：

```sh
# 复用已 clone 的 ghostty 源（避免每次 cargo clean 后重新 clone）
export GHOSTTY_SOURCE_DIR=/path/to/ghostty-src
```

## 会话层（M1）

```rust
let mut session = Session::spawn_default(GridSize { cols: 80, rows: 24 })?;
// UI 每帧调用一次：排空 PTY 输出、喂给 VT、检查子进程
let poll = session.poll()?;
let lines = session.screen_text()?;
session.write(b"ls\r")?;          // 键盘/粘贴字节
session.resize(GridSize { cols: 100, rows: 30 })?;
```

线程模型（由 `!Send` 决定）：

```
PTY 子进程 ──read──> 读线程 ──channel(Vec<u8>)──> owner 线程：Session::poll → TerminalCore::feed
owner 线程 ──write_all──> PTY master
```

- `TerminalCore`、`RenderState` 永远在 owner 线程（桌面端是 GPUI 主线程）。
- 读线程只持有 `Box<dyn Read + Send>` 和 channel，不接触 VT 状态。
- `Session::poll` 非阻塞；`exit` 每次返回当前已知状态，`None` 表示仍在运行。
- `Drop` 会 kill 并回收子进程，不会留僵尸。
- 子进程环境固定设置 `TERM=xterm-256color`、`COLORTERM=truecolor`、`TERM_PROGRAM=cgc-desktop`。

## 测试

```sh
cargo test -p cgc-terminal
```

覆盖：

- VT 核心：样式化文本、光标移动与擦除、双宽字符（CJK/emoji）、resize 后 reflow
- 会话层：输出捕获 + 退出码、写入到达子进程、resize 传播到 PTY（`stty size` 断言）

## 许可证

- `libghostty-vt`：MIT OR Apache-2.0
- `portable-pty`：MIT
- `unicode-width`：MIT OR Apache-2.0

均与 AGPL-3.0 兼容。
