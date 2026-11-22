---
status: accepted
date: 2026-10-19
---

# ADR-0027：桌面客户端的分发、更新与签名

> 日期：2026-10-19 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：架构脊柱 `_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（AD-11、AD-12、AD-13）

## 背景（Context）

桌面客户端要覆盖 macOS / Windows / Linux 三平台分发与升级。gpui-kit 明确不提供发布选择与安装替换（`website/docs/auto-update.md`），因此更新器、签名与分发都是客户端自建能力。当前 Apple Developer 与 Windows 代码签名证书均未持有。

## 决策（Decision）

1. **分发与更新器分阶段演进（2026-11-22 修订）**：
   - **Phase 1（已落地，无证书阶段）**：不直连 GitHub Releases API 检查更新（规避中国大陆网络可达性风险），改由第一方后端 `GET /api/desktop/version`（免鉴权、零 DB、由 `DESKTOP_LATEST_VERSION` / `DESKTOP_MIN_SUPPORTED_VERSION` / `DESKTOP_BLOCKED_VERSIONS` / `DESKTOP_KILL_SWITCH` / `DESKTOP_DOWNLOAD_URL` / `DESKTOP_RELEASE_NOTES` 环境变量驱动）作为唯一版本控制面。客户端启动时通过 `cgc_platform::update::check_for_update` 发起一次轻量检查：发现可选新版本时在顶栏下方展示可关闭更新提示横幅；命中强升、停用或止损开关时展示全窗不可关闭引导覆盖层。下载跳转链接强制过官方 HTTPS 白名单（`codingirlsclub.com` 及其子域、或官方仓库 `github.com/CodingGirlsClub/cgc_2046` Releases），由系统浏览器打开下载。
   - **Phase 2（证书到位 / GA 后，见 #1324）**：待三平台代码签名公证与国内可达镜像就绪后，评估演进为应用内静默下载、**校验 SHA-256 与代码签名后**原子替换安装并在安全时点重启，保留上一版本、失败自动回退（AD-12）。
2. **签名双态与打包格式（2026-11-22 修订）**：证书到位时 macOS 使用 Developer ID 签名 + notarization、Windows 使用代码签名（见 #1324）；未到位时产出 ad-hoc / 未签名内部测试构建，并在发布说明记录正式发布阻塞。**Linux 正式放弃 AppImage**（避免 FUSE / `libsecret` 运行时兼容问题），统一产出 `.deb` 与由 `.deb` 解包生成的便携 `tar.gz`（内置 `register-protocol.sh`）。
3. **首个对外版本双态**：证书到位则正式对外发布；未到位则交付内部测试版，正式对外发布挂在证书采购之后（#1324）。**无证书的构建只能进内部通道，不得对外发布**。
4. **兼容窗口与版本门控（已落地）**：后端 GraphQL 只增不删至 min-supported-version；桌面 operation 纳入 `pnpm check:release-schema`（`desktop/scripts/check_release_schema.py`）。
   - **版本头与 426 门控**：桌面端所有第一方出口（GraphQL、登录会话、MCP HTTP、ACP MCP 注入、`/mcp/token` 核验与 CGC Cloud `/v1/*` 网关；不含外部图片拉取与 BYOK provider）统一随请求发送 `x-cgc-client: desktop`、`x-cgc-client-version`（单一真源取 `CGC_BUILD_VERSION`）与 `x-cgc-client-platform`。后端无状态 `DesktopClientGatePlug` 挂载于 `:graphql`、`:mcp`（豁免 `DELETE /mcp/token` 登出撤销）与 `:llm_gateway`（开启 `kill_switch` 时连无头旧包一并拦截）最前端，拒绝固定返回 HTTP `426 Upgrade Required`（不误用 `401`，不触发客户端 `force_sign_out` 清凭证）。桌面端收到 `426` 后置位进程级 `UpgradeNotice` Latch、暂停通知轮询并在 `RootView` 渲染升级/止损引导覆盖层。多版本共存后的跨版本兼容 fixture 归 #1324。
5. **通知策略**：应用在前台或托盘常驻时发本地系统通知，启动时拉取未读事件补发；离线提醒复用已有的微信订阅消息渠道，桌面端 v1 不做 APNs / WNS push；托盘常驻可由用户关闭。
6. **通知与深链**：feature 只向事件总线发领域事件；OS 适配器消费事件生成系统通知与 `cgc://` 深链跳转；单实例与托盘同属 OS 适配器（AD-11）。**（2026-11-22 修订：单实例、托盘与 keychain 等 OS 适配均直接位于 `crates/platform` 内按 `#[cfg(target_os = ...)]` 条件编译隔离，不拆独立 `platform-{macos,windows,linux}` crate。）**
7. **隐私与遥测**：崩溃遥测默认关闭、可随时关闭；日志与遥测不得含凭证与对话内容（AD-13）。
8. **数据保留**：升级与回滚不得丢用户数据与凭证；keychain 中的凭证跨版本兼容。
9. **双通道版本矩阵**：浏览器路径的 `cgc-host` 继续独立发版（`ext/cgc-host` + `MIN_HOST_VERSION`）；客户端内置 Host 随客户端版本更新，两者共享行为不变量。**（2026-10-26：Web 端学习搭子与 `cgc-host` 已移除，浏览器路径不再发版，本项仅作历史记录。）**

## 否决的替代

- **仅靠安装器管理更新**（如仅 Inno Setup / DMG 覆盖安装）：用户需手动下载，无法满足「持续升级」体验；更新器仍需要，安装器只是安装形态。
- **无证书直接对外发布**：macOS Gatekeeper 与 Windows SmartScreen 会拦截或警告，不适合面向学员的正规分发。
- **应用商店上架作为 v1 渠道**：审核周期与合规成本高，v1 不走商店，保留后续可能。

## 后果（Consequences）

- **正面**：更新链路可控；证书未到位不阻塞开发，只阻塞正式发布；通知/深链/单实例统一在 OS 适配器。
- **代价/风险**：更新器、签名、公证、回滚均需三平台真机验证；证书采购时间与预算未知，是首个正式对外版本的阻塞项；GitHub Releases 在中国大陆的网络可达性需要真机验证，必要时加国内镜像（后续决策）。
- **回滚**：停用客户端更新器并冻结版本即可；不影响后端与 web。

## 参考

- gpui-kit 自动更新边界：https://github.com/longbridge/gpui-kit/blob/main/website/docs/auto-update.md
- 架构脊柱：`_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`
