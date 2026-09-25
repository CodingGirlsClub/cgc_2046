# openclacky-ext（OpenClacky 扩展）

CGC-2046 的 OpenClacky 连接器扩展，包实体在 `cgc-2046/`（Ruby API handler + 面板 + 三助手 agent + onboarding skill + hooks），要求宿主 openclacky ≥ 1.3.7。架构、目录结构、安全约定、安装后验收的全文见 `cgc-2046/DEVELOPMENT.md`（不进分发包）；用户文档见 `cgc-2046/README.md`。

## 版本纪律（发版红线）

- **分发内容一变就必须 bump** `cgc-2046/ext.yml` 的 `version`，并把 `cgc-2046/CHANGELOG.md` 的 `[Unreleased]` 段挂到该版本号下——用户面板的「升级」按钮完全取决于这个号，同版本号 ≠ 同一份产物，忘 bump 用户就静默停在旧构建。
- 发版前自查：`cgc-2046/bin/check-version-bump`（内容指纹变了版本没动 → 非零退出并给修法；deploy CI 同脚本强制）。指纹按 zip 内逐条目 sha256 + 路径聚合，与 zip 字节无关（zip 含条目 mtime），别拿 zip sha256 当内容变更判据。
- 仓库根 `CHANGELOG.md` 的端标签节点用 `[扩展 vX]`（发布纪律见根 `AGENTS.md`）。

## 开发回路

- `cgc-2046/bin/pack` 把本目录 symlink 到 `~/.clacky/ext/local/cgc-2046`（openclacky 开发层）：改完文件即生效（handler 按请求热加载），无需重复打包。产物 zip 在 `openclacky-ext/dist/`（gitignored，不入库）。
- 配置点唯一：`ext.yml` 顶层 `config.mcp_url` / `config.web_url` 是全包仅有的改 URL 处（默认生产值）；本地联调改本地副本（`http://localhost:4000/mcp` / `http://localhost:3000`），connect 端点 body 的 `url` 字段可临时覆盖。
- `bin/`、`test/`、`DEVELOPMENT.md` 经本目录 `.gitignore` 排除、不进 ext pack——**新增 `bin/` 脚本要 `git add -f`**。

## 测试

需 mise 环境的 Ruby（系统 ruby 缺 openclacky gem）：

| 目的 | 命令 |
| --- | --- |
| 全量单测（minitest，stdlib，请求级不落盘） | `cd openclacky-ext/cgc-2046 && for f in test/*.rb; do mise exec -- ruby "$f"; done` |
| 面板行为 harness（node 驱动 view.js，DOM 断言） | `test/panel_behavior_harness.js` |

安装后五步验收见 `DEVELOPMENT.md`「验证步骤」。

## 安全红线（扩展面）

- token 只落 `~/.clacky/mcp.json`（0600，原子写）；handler 响应体、日志、data_path 文件一律不含 token；`status` 只回 `configured` / `url` / `token_configured` / `web_url`。
- token 不进 argv、对话消息、工具参数；凭证脱敏正则在两 hook 间共享（`hooks/credential.rb`），改一处想两处。
- 所有路由要求请求 `Host` 为 loopback，缺失或非 loopback 一律 403 `host not allowed`；写路由（POST 及 `DELETE /connect`）另需同源下发的 CSRF token。
- 导航外链（`web_url` 及深链、`checkout_url`）一律过共享骨架 `CgcKit.safeWebUrl` scheme 门：https 任意 host、http 仅 loopback，非法 ≡ 未配置（隐藏入口/退化纯文本）；拼进 HTML 属性的 URL 一律 `escapeHtml`。
- connect 的条目名写死 `cgc-2046`，不动 mcp.json 其他 server 条目，更新时保留该条目未知额外键。

## License

分发协议 AGPL-3.0-only（与根 LICENSE 一致）；新 gem / npm 依赖过根 `AGENTS.md` 的「依赖与 License 合规」门禁。
