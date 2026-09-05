# 邮件与 CD 环境注入契约

> 关联：issue #164（邮件基建 CD 就绪）
>
> 本文档定义生产环境邮件（SendCloud）相关环境变量的**注入契约**：五个值放在哪、谁消费、上线前检查什么、CI 的边界在哪。它是后续 deployment/release workflow 与运维人员的唯一事实来源。

## 1. 五值清单与类型

生产邮件链路由五个环境变量驱动。按「可变性 + 敏感度」分成两类：

### Secrets（敏感，绝不放入 Variables）

| 变量 | 类型 | 说明 |
|---|---|---|
| `SENDCLOUD_API_USER` | GitHub Actions **Secret** | SendCloud 普通发送 apiUser（登录用户名） |
| `SENDCLOUD_API_KEY` | GitHub Actions **Secret** | SendCloud 普通发送 API 密钥 |

**硬约束**：密钥绝不放 Variables。Actions `vars` 会明文出现在 runner 环境与可审计日志中，任何凭据都只进 `secrets`。

### Variables（非敏感可变值）

| 变量 | 类型 | 说明 |
|---|---|---|
| `SENDCLOUD_FROM` | GitHub Actions **Variable** | 已认证的发信地址（邮箱） |
| `SENDCLOUD_FROM_NAME` | GitHub Actions **Variable** | 发件人显示名（如密码重置邮件署名） |
| `WEB_BASE_URL` | GitHub Actions **Variable** | 生产公开 HTTPS web 源（密码重置链接用），如 `https://app.example.com` |

这些值本身非敏感但可能调整（发信地址、显示名、域名），放 Variables 便于环境级覆盖且不污染审计日志。

## 2. 消费方

### 唯一运行时消费方：backend `config/runtime.exs`

生产模式下（`config_env() == :prod`）唯一读这五个值的地方是 `backend/config/runtime.exs`：

- `WEB_BASE_URL`：`:48-67`，prod 必填且强制 HTTPS（`URI.parse(...).scheme != "https"` 时 raise）；非 prod 默认 `http://localhost:3000`。
- 四个 `SENDCLOUD_*`：`:174-210`，prod 必填，缺任一个 release 启动即 raise（fail-fast，杜绝半配置启动），最终写入 `config :cgc_2046, Cgc2046.Mailer`。

消费端实现：`backend/lib/cgc_2046/swoosh_adapters/send_cloud.ex`（Req POST `api.sendcloud.net/apiv2/mail/send`，`required_config: [:api_user, :api_key, :from, :from_name]`）。

**本地生产模式**需显式 export 全部五值，例如：

```bash
export SENDCLOUD_API_USER=your_api_user
export SENDCLOUD_API_KEY=your_api_key
export SENDCLOUD_FROM=no-reply@example.com
export SENDCLOUD_FROM_NAME="CGQ 2046"
export WEB_BASE_URL=https://app.example.com
MIX_ENV=prod mix release
```

不 export 会在 release 启动时收到明确 raise 提示，属预期 fail-fast 行为。

### 生产注入块（GitHub Actions）——已接线

> **2026-08-22 更新**：`.github/workflows/deploy.yml` 已落地（#213），本节原「未来 workflow 骨架」退役，以真实实现为准：
>
> - **backend job**：`SENDCLOUD_API_USER/API_KEY`（secrets）与 `SENDCLOUD_FROM/FROM_NAME/SMS_*/WEB_BASE_URL`（vars）等 27 项经**非空断言**写入 `.kamal/secrets`——GitHub 漏配 = deploy 首分钟红，kamal deploy 未执行、旧容器继续服务。
> - **web job**：`NEXT_PUBLIC_WEB_BASE_URL` / `BACKEND_URL`（vars）经 sed 注入 Kamal builder args（**构建期内联**进 Next 产物，运行时不可改），同款非空断言（#254）。`NEXT_PUBLIC_WEB_BASE_URL` 是全站 canonical/hreflang/sitemap 的基准 URL（消费方 `web/lib/seo.ts`），为空会把 SEO 面静默焊死成回退值——断言在 sed 之前挡住。
> - 全部 Secrets/Variables 挂 GitHub repo **Environments → `production`**，作用域隔离且可审计。变量登记单源 = deploy.yml 的两处断言名单，本文档不再复制。

## 3. SendCloud 前置检查单（首次上线前）

> 执行留档（#216）：逐项核对后勾选并署日期；第 1 项若 apiUser 不支持普通发送，升级为阻塞问题裁决（换套餐/换服务商）。

- [ ] **apiUser 权限**：`SENDCLOUD_API_USER`/`SENDCLOUD_API_KEY` 必须是**普通发送**权限（非触发类），对应 `/apiv2/mail/send` 端点。
- [ ] **发信域认证**：`SENDCLOUD_FROM` 所在域已配置 SendCloud 发信域，DKIM + SPF 记录生效（否则投递率受挫 / 被拒）。
- [ ] **生产 WEB_BASE_URL 必须 HTTPS**：runtime.exs 已强制，运维侧确保域名有有效 TLS 证书，重置链接绝不经明文传输。
- [ ] **发送丢失风险（已知现状，不在本轨改）**：密码重置邮件经 `Task.start` fire-and-forget 发送，失败不重试、不告警、无持久化队列。生产上线前如需强投递保证，另行评估（如接入持久化队列/重试），当前不在本计划范围内修改——**勾选 = 接受该现状上线**。

## 4. CI 边界

- **ci.yml 不注入生产邮件凭证**：现状保持。`.github/workflows/ci.yml` 用 `MIX_ENV: test` 跑 backend 测试，不含任何 `SENDCLOUD_*` 生产值；其 `secrets` job 是 gitleaks 密钥扫描（fail-closed），与此注入无关。
- **test/dev 用 Test adapter + `/mailbox`**：非生产环境不触 SendCloud。Swoosh 在 test 环境走 `Swoosh.Adapter.Test`，开发环境预览走 `router.ex` 的 dev_routes block 内 `/mailbox`（`Plug.Swoosh.MailboxPreview`，见 `backend/lib/cgc_2046_web/router.ex` 的 `:dev_routes` 分支）。测试见 `backend/test/.../send_cloud_test.exs`、`password_reset_test.exs`。

## 5. 交付边界

- ~~真实创建 GitHub Actions Secrets/Variables 推迟到**部署目标确定**时~~ **已解除**（2026-08-22）：deploy workflow 已落地并消费全部值，生产在跑。新增变量的流程 = Environments → `production` 创建 + deploy.yml 断言名单登记（漏任一侧 deploy 首分钟红，见 §2）。
