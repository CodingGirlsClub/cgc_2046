---
status: accepted
date: 2026-10-19
---

# ADR-0024：桌面客户端技术栈——GPUI + gpui-kit

> 日期：2026-10-19 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：Desktop 客户端 initiative（`_bmad-output/initiative-desktop/initiative-desktop.md`）、架构脊柱 `_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（AD-1、AD-2、AD-9、AD-10、Stack）

## 背景（Context）

平台现有 web（Next.js + React）、小程序（Taro）与终端/OpenClacky 路径，学员学习仍以浏览器为主。决定新增面向学员的原生桌面客户端，作为学习主入口：登录、工作台、场次与报名支付、课程学习、学习搭子对话。后端为 Elixir / Phoenix + Ash GraphQL，客户端不得引入平台侧新业务语义。

候选栈比较过 Tauri 2、Electron、Flutter 与 GPUI + gpui-kit。选 GPUI 的核心权重是：一套 Rust 代码交付三平台、原生 GPU 渲染、无 WebView 引擎差异（web 端已知的 WebView / 回环限制不再存在）、gpui-kit 提供组件、AccessKit、UI 集成测试与打包/更新指引（Apache-2.0）。代价是放弃 web 的 React 组件复用，UI 全重写。

## 决策（Decision）

1. **技术栈 = Rust + GPUI，经 `gpui-kit` 0.7.3 使用**。工具链下限 **Rust 1.92+**（gpui-kit 安装要求，且 `gpui-pre-linux → oo7 0.6.0` 的 `rust_version = 1.92`），以 `rust-toolchain.toml` 固定。`gpui-kit` 以 `=0.3.9` 精确钉死 `gpui-pre`（zed@93d7456）；不得单独升级或覆盖其中某个 GPUI 包，也不得直接依赖 crates.io 的 `gpui` 0.2.2——两者不兼容，同时引入会产生两份 GPUI。
2. **分层与依赖方向**：`crates/app`（组合根）→ 各 domain crate（account / events / courses / companion）；domain crate 只依赖 `platform` 的端口 trait；OS 适配器按 Zed 的 `gpui_platform` + `gpui_macos/linux/windows` 同构拆成 `platform-{macos,windows,linux}`，各自实现端口并依赖 `platform` 的端口类型；domain crate 之间不互相 import（脊柱 AD-1）。布局对齐 Zed：`crates/` 下每个子系统一个 crate，`app` 是唯一 binary crate；加功能默认进已有 crate 的 module，不按功能清单建 crate。
3. **业务数据单一来源 = 后端 GraphQL schema**：客户端用 schema 生成 Rust 类型，只写视图模型与可失效缓存（AD-2）；GraphQL 代码生成工具在 epic-2 选定并锁版（生成物只读）。
4. **路由与 i18n 只追加**：并行 epic 向注册表追加条目，不修改共享文件的可变区域（AD-9）。
5. **内容渲染**：Markdown/HTML 用 gpui-kit TextView；数学公式渲染方案在 epic-4 决定——候选 `ratex-gpui` 0.4.1（MIT），但须锁与 gpui-kit 相同的 `gpui-pre` 快照，否则改为预渲染 SVG；须用真实课程内容回归。
6. **平台底线**：macOS 15+；Windows 10+（MSVC，需 CMake 在 PATH）；Ubuntu 24.04（Wayland 与 X11 均受支持，回归矩阵在 epic-1 决定；需可用 Vulkan 驱动）。
7. **新增依赖须过 AGPL-3.0 许可门禁**：Rust 依赖树新增 `cargo-deny` 类扫描；GPL-3.0 类先人裁（`docs/开源合规/依赖引入规则.md` 第 6 节）。

## 否决的替代

- **Tauri 2 + React 复用**：web UI 复用率高，但 Next.js 服务端渲染无法直接复用，仍需独立 SPA；且三平台仍是三套 WebView，桌面端只是「更轻的浏览器壳」，不足以支撑学习主入口定位。
- **Electron**：包体积与内存代价大，对教育类客户端不划算。
- **Flutter**：UI 全重写且与现有 React/TS 生态割裂，桌面生态弱于移动。
- **WASM / QuickJS 扩展框架**：见 ADR-0026 的注册表路线，v1 不做。

## 后果（Consequences）

- **正面**：一套代码三平台；无 WebView 引擎差异；原生性能与无障碍；GPUI 与本地 agent 驱动同为 Rust 进程模型。
- **代价/风险**：引入 Rust 为项目第三种主语言，团队与招人成本上升；UI 零复用，需重建设计系统与组件；上游 `gpui` 发布停滞，供应链实际依赖 gpui-kit 维护方，须锁版并保留自建 patch 路径；Windows 平台有已知 TitleBar 类 bug，需真机验收。
- **回滚**：本 ADR 只约束新代码；若未来放弃 GPUI，客户端可整体替换，不影响后端与 web。

## 参考

- 架构脊柱：`_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`
- gpui-kit：https://gpui-kit.com/zh-CN/docs
- Zed Windows 支持：https://zed.dev/blog/zed-for-windows-is-here
- 依赖规则：`docs/开源合规/依赖引入规则.md`
