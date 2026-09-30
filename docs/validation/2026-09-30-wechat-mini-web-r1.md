# R1：小程序确认 Web 登录基础能力验收

对应 #1029，基线 `93ba9a99`。R1 包含后端、小程序及依赖安全修复；不切换 Web 入口。R2 对应 #1030，须等 R1 实际发布、小程序正式确认页与真机矩阵通过后再合并。

## 依赖审计修复

- fast-uri 3.1.6 → 3.1.7（BSD-3-Clause）、brace-expansion 1.1.18 → 1.1.20（MIT）。
- webpack-dev-middleware 5.3.4 → 7.4.6（MIT）：5.x 无修复版，采用上游修补输出目录边界的 7.4.6。Node 最低要求 18.12，项目 CI 使用 Node 24。通过 Taro 实际 webpack-dev-server 实例验证编译、正常资源响应、越界拒绝和关闭，覆盖大版本替换的主要调用契约。
- pnpm 10 生成锁文件；从干净 `origin/develop` 加相同 overrides 后再次生成，锁文件逐字节一致。没有手改锁文件、关闭审计或新增豁免。
- 回归测试旧 middleware 返回越界测试文件（HTTP 200），升级后返回 403；正常 bundle 仍为 200。测试仅访问临时目录和编译器内存文件系统的合成文件。
- `pnpm audit:prod` exit 0：high 已清零；2 low、13 moderate 和原有 swiper critical 豁免保持原样。`pnpm check:licenses` 对 4247 个依赖通过。

上游依据：[7.4.6 发布说明](https://github.com/webpack/webpack-dev-middleware/releases/tag/v7.4.6)、[7.0.0 Node/memfs 变更](https://github.com/webpack/webpack-dev-middleware/releases/tag/v7.0.0)。

## 正式构建配置

在当前独立 checkout 通过 ignored 本地链接复用已有 `.env.prod`，仅由构建工具读取；没有查看、打印或提交配置值，没有修改生产配置。执行 `NODE_ENV=production CGC_E2E_MOCK=false pnpm build:weapp` 后，`pnpm check:release-endpoint weapp` 通过，产物使用正式 HTTPS API 地址，主包 1,138,975 bytes。dist 不入库，也未上传。

复跑时必须在实际上传对应 checkout 配置正式构建环境；先完成 `pnpm check:ci`（末尾会生成 mock 包），再显式重建非 mock 正式包并检查 endpoint，不能把 CI 留下的 mock 包上传。

## 验证与发布边界

本地完整 `pnpm check:ci` 通过：audit、codegen 新鲜度、类型、许可、386 个 node:test、232 个 Vitest、三端构建、包体积、零导流、xhs 分享配对、mock anchors 与 E2E 文档对账。Backend 认证专项及全量、Web 保持旧入口的全量验证结果见 PR 验证记录。

原登录功能回归覆盖 proof/Origin/平台身份、显式确认、一次领取、JWT 撤销事务回滚、JPEG、IP 限流后内存键不增长、小程序确认结果未知。此前微信工具异常场景已通过；切分后的依赖更新仍须以当前 head 检查为准。

本报告是源码交付验证，不是发布批准。数据库迁移和锁文件需人工合并；不部署、不上传、不操作生产数据。真实微信手机号授权、A02 完整已有业务数据互通、生产等价 Cookie 域隔离及设备矩阵是 R2 合并/上线门。

## PR 复审补充

确认／确认结果未知／本地退出的状态迁移已集中到 `domain/web-login.ts` 的纯 reducer 与 view；页面通过 `useReducer` 接入。新增两条 Node 回归覆盖未知确认后退出、非 APPROVED 响应、确认成功与退出终态，先红后绿，并将退出丢弃尝试事实的实现变异为红、还原为绿。完整小程序 CI 与六场景微信模拟器 E2E 再次通过，最后重新生成正式非 mock 包并检查 endpoint 与体积。
