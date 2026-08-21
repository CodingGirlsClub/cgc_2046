# ADR-0008: 浏览器会话唯一归属主域——api 子域只服务非浏览器客户端

> 日期：2026-08-21 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：KD3（`docs/plans/2026-08-10-001-feat-platform-admin-dashboard-plan.md`，面向人的管理台共享 httpOnly cookie 的先例）、issue #254（回跳类 env 注入 checklist）、部署形态（Kamal 同机双容器 + kamal-proxy 按 Host 分流）

---

## 背景（Context）

- 平台有**一套**身份体系，生产却有**两个**浏览器可达 origin：`codingirlsclub.com`（Next.js 前端）与 `api.codingirlsclub.com`（Phoenix）。
- 登录态 `cgc_token` cookie 由 GraphQL `before_send` 写入，**host-only**（未设 `Domain` 属性）——经前端 rewrite 链路落在主域。
- AshAdmin 调试面 `/ops/admin` 挂在 Phoenix 上，鉴权链（`AuthCookiePlug :read → load_from_bearer → PlatformAdminPlug`）完全依赖该 cookie。结果：**主域无 `/ops` 路由（404），api 域无 cookie（403）**——生产两个域都不可达。
- dev 从未暴露：web `localhost:3000` 与 api `localhost:4000` 同属 host `localhost`，cookie 不区分端口天然共享——典型 dev/prod 奇偶性陷阱。

## 决策（Decision）

1. **浏览器会话唯一归属 `codingirlsclub.com` 一个 origin。** `api.codingirlsclub.com` 只服务非浏览器客户端（`Authorization: Bearer` / 渠道验签 webhook / MCP 连接 token）。
2. 任何需要会话的浏览器面必须经主域路由到达：`/ops/*` 由 kamal-proxy **path 路由**直达 backend 容器（backend `ops` role，`host: codingirlsclub.com` + `path_prefix: /ops`，不 strip prefix），不经 Next.js。
3. **所有回跳/链接类 env 必须指向主域**（`ALIPAY_RETURN_URL`、`WEB_BASE_URL`、`PAYMENTS_WEBHOOK_BASE_URL` 例外——它接收的是支付宝服务器回调，非浏览器，指 api 域正确）。
4. cookie 保持 host-only（最小权限），禁止放宽为 `domain: .codingirlsclub.com`。

### 拒绝的替代

- **`domain: .codingirlsclub.com`：** cookie 下发全部子域（含 `oc.` 等半外部系统），任一子域被接管 = 全平台会话被接管；放大 CSRF/凭据附带面，与 `SameSite=Lax` 初衷相抵。一行能修但安全债务永久。
- **ops 面在 api 域建立独立会话（专用登录页）：** 多一个公开登录面要加固、管理员双登录、与「单一会话 origin」规则打架。仅当 path 路由遇到 kamal-proxy 硬限制时回退。
- **Next.js rewrite 代理 `/ops`：** rewrites 在 standalone 模式不代理 WebSocket upgrade，AshAdmin 的 LiveView 会挂；且管理面流量过 Next 容器无收益。

## 后果（Consequences）

- **正面：** `/ops/admin` 在主域登录态下直接可用（管理员直觉 URL）；Phoenix/Next 业务代码零改动（只动「谁在哪个 URL 上被看见」）；WebSocket 由 kamal-proxy 原生支持。
- **实现细节（已固化）：** Phoenix 挂 `/ops/live` socket（`check_origin` 显式含主域）+ `ash_admin(..., live_socket_path: "/ops/live")`；未登录 `/ops/admin` → 403（`PlatformAdminPlug`）纳入部署冒烟（404 = path 规则失效红线）。kamal-proxy path 前缀路由优先于同 host 的 catch-all 服务，已在生产实证（临时探针 `/opsprobe/healthz` → backend `ok`，2026-08-21）。
- **代价/风险：** backend 起第二个容器（同镜像，内存 +1 份 BEAM）；api 域上的 `/ops` 维持 403 现状（无 cookie 永远 403，无害）。
- **同族遗留（另案处理）：** 反向代理链上 client IP 默认丢失——所有 per-IP 限流退化成全站共享一个桶（`conn.remote_ip` 恒为代理容器 IP），需 `remote_ip` 类方案修复，独立推进。
