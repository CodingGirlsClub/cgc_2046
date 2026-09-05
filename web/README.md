# web（cgc-2046 前端）

Next.js 16（App Router + Turbopack）+ next-intl + Apollo Client。后端为仓库根的 Phoenix 应用，dev 下 `/api/graphql` 经 rewrites 转发到 `BACKEND_URL`。

## 快速开始

```bash
pnpm install
cp .env.example .env.local   # 按需修改
pnpm dev                     # http://localhost:3000
```

常用命令：`pnpm dev` / `pnpm build` / `pnpm typecheck` / `pnpm lint` / `pnpm test`。

环境变量说明见 [.env.example](.env.example)（不进 git）。

## 真机联调（手机访问 dev server）

手机浏览器经 LAN IP 访问时（如 `http://192.168.3.100:3000/login`），Next 16 dev server 默认 block 非 localhost origin 的 `/_next/*` 静态资源与 HMR——整页 JS 失效，症状为按钮 onClick 无反应、表单退化浏览器原生 GET 提交（密码明文进 URL）。见 [#251](https://github.com/CodingGirlsClub/cgc_2046/issues/251)。

放行步骤：

1. 开发机查 LAN IP（如 `ipconfig getifaddr en0`），在 `web/.env.local` 设置：

   ```bash
   WEB_DEV_ORIGINS=192.168.3.100
   ```

   逗号分隔可配多个（`192.168.3.100,192.168.1.20`）；值写 hostname 即可，带 scheme/端口也会被归一化。

2. **重启 `pnpm dev`** —— `next.config.ts` 只在启动时读取，改 env 不重启不生效。

3. 手机与开发机同一 WiFi，访问 `http://<开发机IP>:3000/login`。dev 日志不应再出现 `Blocked cross-origin request ... from "192.168.x.x"`。

> 已知干扰（dev-only，非代码 bug）：真机访问 + 登录跳转后 Next 16.3 dev overlay 可能弹 `TypeError: Cannot write to a CLOSED writable stream`，为 Next dev console 转发流内部问题，点 ✕ 关闭即可，不影响生产（#251 评论实测）。

## 部署

生产构建为 standalone 模式（`output: "standalone"`），由仓库根 Docker 部署链构建；`BACKEND_URL` 生产缺失会 fail-fast（#213）。勿用 Vercel 模板流程。
