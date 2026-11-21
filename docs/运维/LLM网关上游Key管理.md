# LLM 网关上游 Key 管理

> 关联：PR #1304（Provider Catalog）、#1305（部署门禁）、#1306（解密兼容与重加密）
>
> 本文档定义上游 Provider / API Key 的存放、加密、迁移与故障判定，是运维侧唯一事实来源。

## 1. 三层凭证

| 层 | 位置 | 谁能改 | 作用 |
|---|---|---|---|
| Provider API Key（`sk-...`） | 数据库 `llm_provider_api_keys.encrypted_api_key` | 平台管理员（Admin 后台） | 调上游模型 |
| 加密主密钥 `LLM_GATEWAY_ENCRYPTION_KEY` | GitHub Secret → Kamal `env.secret` → 容器环境 | 仓库管理员 | 加密上表密文 |
| 上游控制台账号 | DeepSeek / 火山方舟控制台 | 运营 | 重发 API Key 的根凭证 |

主密钥**不得**入库、不得进 Admin 后台：与密文同库等于没加密。

## 2. 日常流程

1. Admin 后台录入 Provider（base_url、protocol、priority）→ 录入 API Key → 配置模型与定价。
2. 后台只展示 `key_preview`（脱敏）与 `key_fingerprint`（SHA-256），**任何界面都不返回明文**。
3. 轮换某把上游 Key = 在上游控制台重发，然后在后台覆盖录入；不需要也无法先“读出来”。

## 3. 加密与回落

- 算法：AES-256-GCM，密钥由 `sha256("cgc_2046:llm_gateway_key:v1:" <> master)` 派生。
- 解密顺序：`LLM_GATEWAY_ENCRYPTION_KEY` → `secret_key_base` 回落。独立主密钥上线前写入的密文因此仍可读。
- 新写入永远用主密钥。

## 4. 迁移历史密文（发布 #1306 之后执行一次）

运行时镜像只有 `bin/cgc_2046`，没有 mix：

```bash
bin/cgc_2046 eval "Cgc2046.Release.reencrypt_llm_keys"
```

源码环境：

```bash
mix cgc2046.reencrypt_llm_keys
```

输出与退出码：

- `reencrypted N llm provider api key(s)` + 退出 0：全部迁移完成。
- `... F could not be decrypted and must be re-entered in the admin console` + 退出 1：有坏行，保留原样，需后台重录。
- `LLM_GATEWAY_ENCRYPTION_KEY is not configured` + 退出 1：主密钥没注入容器，先查 Kamal secret 名单。

**未完成迁移前不要轮换 `secret_key_base`**：回落密钥是旧密文的唯一依靠。

## 5. 故障判定链

| 现象 | 判定 | 动作 |
|---|---|---|
| `/v1/models` 有模型，`/v1/chat/completions` 全 503 | 候选渠道为空：解密失败或 Key/模型被禁用 | 查日志关键字 `cannot be decrypted` 或 `still encrypted with the fallback` |
| 日志 `cannot be decrypted ... key_id=<uuid>` | 当前主密钥与密文不匹配（换过 key / secret 丢失） | 上游重发 Key → 后台重录 |
| 日志 `still encrypted with the fallback secret_key_base key` | 旧密文尚未迁移 | 执行第 4 节命令 |

两条日志都按 `key_id` 限流 10 分钟，只含 provider slug、key ID 与指纹前 8 位。

## 6. 已知限制

- **主密钥 A → B 轮换不直接支持**：候选列表只有当前主密钥与 `secret_key_base`，旧主密钥不在其中，重加密会把相关行计入 `failed`。轮换时要么后台重录，要么另加 `PREVIOUS` 双密钥窗口。
- 主密钥一旦丢失且未备份：只能放弃旧密文，在上游控制台重发并重录。上游控制台是 Provider Key 的权威副本，业务数据（钱包、用量、订单）不受影响。
