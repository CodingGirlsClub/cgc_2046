# 邮件与 CD 环境注入契约

> 关联：issue #164（邮件基建 CD 就绪）；plan `docs/plans/2026-08-15-022-email-infra-cd-readiness-plan.md`
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

### 生产注入块模板（GitHub Actions）

> **部署目标确定后启用**：以下片段仅供未来 production deploy/release workflow 参考，当前仓库无部署信号（无 vercel/fly/docker 配置），未接线到任何 workflow。

```yaml
# 未来 production deploy/release workflow 中的注入块（骨架）
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production          # 环境级 Secrets/Variables 在此作用域解析
    env:
      SENDCLOUD_API_USER: ${{ secrets.SENDCLOUD_API_USER }}
      SENDCLOUD_API_KEY: ${{ secrets.SENDCLOUD_API_KEY }}
      SENDCLOUD_FROM: ${{ vars.SENDCLOUD_FROM }}
      SENDCLOUD_FROM_NAME: ${{ vars.SENDCLOUD_FROM_NAME }}
      WEB_BASE_URL: ${{ vars.WEB_BASE_URL }}
    steps:
      # ... checkout / build / release 步骤（部署目标确定后补充）
```

`environment: production` 是**必需**的：它把 job 的 env 解析限定到 `production` 环境，Secrets/Variables 的创建与更新都挂在 GitHub repo 的 Environments 设置里，天然隔离且可审计。

## 3. SendCloud 前置检查单（首次上线前）

1. **apiUser 权限**：`SENDCLOUD_API_USER`/`SENDCLOUD_API_KEY` 必须是**普通发送**权限（非触发类），对应 `/apiv2/mail/send` 端点。
2. **发信域认证**：`SENDCLOUD_FROM` 所在域已配置 SendCloud 发信域，DKIM + SPF 记录生效（否则投递率受挫 / 被拒）。
3. **生产 WEB_BASE_URL 必须 HTTPS**：runtime.exs 已强制，运维侧确保域名有有效 TLS 证书，重置链接绝不经明文传输。
4. **发送丢失风险（已知现状，不在本轨改）**：密码重置邮件经 `Task.start` fire-and-forget 发送，失败不重试、不告警、无持久化队列。生产上线前如需强投递保证，另行评估（如接入持久化队列/重试），当前不在本计划范围内修改。

## 4. CI 边界

- **ci.yml 不注入生产邮件凭证**：现状保持。`.github/workflows/ci.yml` 用 `MIX_ENV: test` 跑 backend 测试，不含任何 `SENDCLOUD_*` 生产值；其 `secrets` job 是 gitleaks 密钥扫描（fail-closed），与此注入无关。
- **test/dev 用 Test adapter + `/mailbox`**：非生产环境不触 SendCloud。Swoosh 在 test 环境走 `Swoosh.Adapter.Test`，开发环境预览走 `router.ex` 的 dev_routes block 内 `/mailbox`（`Plug.Swoosh.MailboxPreview`，见 `backend/lib/cgc_2046_web/router.ex` 的 `:dev_routes` 分支）。测试见 `backend/test/.../send_cloud_test.exs`、`password_reset_test.exs`。

## 5. 交付边界

- 真实创建 GitHub Actions Secrets/Variables 推迟到**部署目标确定**时：当前无消费方（无 deploy workflow），创建了也是无引用的死配置。届时按本文档 §1 分类在 Environments → `production` 下创建，并按 §2 模板接线。
