# Plan 2026-08-20-007 · 修复 #251：真机 dev 访问整页 JS 被 block + 密码切换命中区

## 根因（issue #251 已取证，2026-08-20 核实仍未修）

Next.js 16 dev server 默认拦截非 localhost origin 的静态资源——手机经 LAN IP 访问时 `/_next/static/chunks/*` 与 HMR 全被 block（dev 日志 `Blocked cross-origin request ... from "192.168.3.x"`），客户端 JS 完全未加载：

- 「显示密码」按钮 onClick 不生效（按钮逻辑本身无 bug——issue 已实测加白名单后 390×844 viewport 切换正常）；
- 表单退化为浏览器原生 GET 提交（**密码明文进 URL + 浏览器历史**）。

代码现状核实（HEAD 6f4866e 后）：`web/next.config.ts` 无 `allowedDevOrigins`；`web/app/globals.css:1577-1593` `.auth-password-toggle` 仍 28×28px。

## 实施单元（web，单 PR，3 小项）

### U1 allowedDevOrigins 可配置

`web/next.config.ts`：dev 场景读 `WEB_DEV_ORIGINS` env（逗号分隔，如 `192.168.3.100,192.168.1.20`）注入 `allowedDevOrigins`。不硬编码内网 IP；未设置时缺省空数组（保持现状，不影响他人）。注意 Next 16 `allowedDevOrigins` 期望 origin 数组（`http://IP:3000` 形态——实施时以 Next 16.3 实际文档/类型为准，env 值允许裸 IP 由代码补全 scheme+port）。

### U2 命中区扩大

`globals.css` `.auth-password-toggle`：28×28 → ≥44×44（视觉尺寸不变：`width/height: 44px` + svg 仍 19px 居中；`right` 偏移微调防溢出输入框，`auth-input--password` 的 padding-right 同步核查）。对齐 iOS HIG 44pt / Material 48dp 下限。

### U3 真机联调文档

`web/README.md`（或既有 dev 文档）补三行步骤：设 `WEB_DEV_ORIGINS=<开发机IP>` → 重启 `pnpm dev`（必须重启才生效）→ 手机访问 `http://<IP>:3000/login`。

## 测试（E2E 按项目 AGENTS.md 确定性分层）

1. **结构断言**（agent-browser）：登录页密码框——眼睛按钮 `getBoundingClientRect` ≥44×44；点击后 `input.type` 切换 `password ↔ text`、aria-label 同步（Show ↔ Hide password）。
2. U1 为 dev server 配置，无浏览器面可断言——以 next.config 类型检查 + dev server 带 env 启动日志无 cross-origin block 为准（手动/冒烟级）。
3. `pnpm typecheck/lint/test/build` 全绿（U1 改 config 需过 build）。

## 验收标准

1. 结构断言全过（命中区尺寸 + 切换行为）。
2. `pnpm typecheck && pnpm lint && pnpm test && pnpm build` 全绿。
3. 文档含真机联调步骤（含「必须重启 dev server」警示）。

## 非目标

- 生产构建行为（allowedDevOrigins 仅 dev 生效，无生产面）。
- 登录页其它 UX（login 线 #250/#255 已交付的表单形态不动）。
- 密码进 URL 的表单退化问题——它是 JS 失效的症状，JS 恢复即消失（按钮修复后表单恢复 JS 提交）；不加防御性 JS。

## 风险

| 风险 | 缓解 |
|---|---|
| allowedDevOrigins 值形态与 Next 16.3 类型不符 | 实施时以 `next/dist/server/config-schema` 实际类型为准；typecheck 兜底 |
| 44px 命中区撑破输入框布局 | svg 视觉尺寸不变仅扩点击区；`auth-input--password` padding-right 核查同步 |
| 并行线（003-005 已合并）文件冲突 | login 线全部 merged，web/auth 面 idle，零冲突 |

## 关联

- Issue #251（关闭目标）
- PR #250/#255（login 线，#251 发现于其联调）
