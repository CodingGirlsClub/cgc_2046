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

1. **分发与更新源 = GitHub Releases**：客户端自建更新器检查版本、下载、**校验 checksum 与代码签名后**安装并在安全时点重启；保留上一版本，失败自动回退；失败时保持旧版本可用（AD-12）。灰度通道后续再定。
2. **签名双态**：证书到位时 macOS 使用 Developer ID 签名 + notarization、Windows 使用代码签名、Linux 产出 AppImage/deb；未到位时产出 ad-hoc / 未签名内部构建，并在发布说明记录正式发布阻塞。
3. **首个对外版本双态**：证书到位则正式对外发布；未到位则交付内部测试版，正式对外发布挂在证书采购之后。**无证书的构建只能进内部通道，不得对外发布**。
4. **兼容窗口**：后端 GraphQL 只增不删至 min-supported-version；桌面 operation 纳入 `pnpm check:release-schema`；整条 document 被拒时降级为可诊断错误页与更新提示，不得白屏；旧客户端通过版本头与 min-supported-version / kill switch 止损；发布前跑跨版本 fixture。
5. **通知策略**：应用在前台或托盘常驻时发本地系统通知，启动时拉取未读事件补发；离线提醒复用已有的微信订阅消息渠道，桌面端 v1 不做 APNs / WNS push；托盘常驻可由用户关闭。
4. **通知与深链**：feature 只向事件总线发领域事件；OS 适配器消费事件生成系统通知与 `cgc://` 深链跳转；单实例与托盘同属 OS 适配器（AD-11）。
5. **隐私与遥测**：崩溃遥测默认关闭、可随时关闭；日志与遥测不得含凭证与对话内容（AD-13）。
6. **数据保留**：升级与回滚不得丢用户数据与凭证；keychain 中的凭证跨版本兼容。
7. **双通道版本矩阵**：浏览器路径的 `cgc-host` 继续独立发版（`ext/cgc-host` + `MIN_HOST_VERSION`）；客户端内置 Host 随客户端版本更新，两者共享行为不变量。**（2026-10-26：Web 端学习搭子与 `cgc-host` 已移除，浏览器路径不再发版，本项仅作历史记录。）**

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
