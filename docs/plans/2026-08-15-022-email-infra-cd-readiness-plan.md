# Plan 022 · 邮件基建 CD 就绪（组5：#164）

- 日期：2026-08-15
- 状态：待评审
- 决策依据：Scout022 取证；用户拍板组5
- 关闭目标：#164（以「就绪文档 + 占位 workflow」形式落地）

## 1. 取证判定

**代码零差距**：SendCloud 全链已在——
- 自定义 Swoosh adapter（`backend/lib/cgc_2046/swoosh_adapters/send_cloud.ex:1-39`，Req POST，required_config 四项）；
- 密码重置完整链路（`send_password_reset_email.ex:1-83` 异步 + `user.ex:327-330` resettable 24h + GraphQL `graphql_schema.ex:506-572` + web 忘记/重置页）；
- 配置面：`runtime.exs:47-68` WEB_BASE_URL（prod 必填 https）+ `:174-210` 四个 SENDCLOUD_* prod 必填 raise；
- 测试在（`send_cloud_test.exs:1-66`、`password_reset_test.exs`）。

**真实差距**：`.github/workflows/` 仅 ci.yml（无 CD），全仓无 `secrets.*`/`vars.*` 引用——#164 要的「落 Actions Secrets/Variables」**无消费点**，且无部署目标时不可真实创建 secret。

**结论**：#164 改为「CD 就绪」交付——文档化注入契约 + 可选占位 deploy workflow，真实 secret 创建推迟到部署目标确定时。邮箱验证确认不存在且 #159 已裁决不做（reset 即所有权验证）。

## 2. High-Level Technical Design

### U1 注入契约文档
`docs/运维/邮件与CD环境注入.md`（新）：
1. 五值清单与类型：Secrets = `SENDCLOUD_API_USER`/`SENDCLOUD_API_KEY`；Variables = `SENDCLOUD_FROM`/`SENDCLOUD_FROM_NAME`/`WEB_BASE_URL`（非敏感可变值放 Variables；密钥绝不放 Variables——scout 风险点）。
2. 消费方：未来 production deploy/release workflow 的 `environment: production` 注入块模板（yaml 片段，标注「部署目标确定后启用」）；backend `runtime.exs:174-210` 是唯一运行时消费方，本地生产模式需显式 export 五值。
3. SendCloud 前置检查单：apiUser 普通发送权限、发信域 DKIM/SPF、prod WEB_BASE_URL 必须 HTTPS、`Task.start` fire-and-forget 发送丢失风险记录（已知现状，不在本轨改）。
4. CI 边界：ci.yml 不注入生产邮件凭证（现状保持）；test/dev 用 Test adapter + `/mailbox`（`router.ex:80-107`）。

### U2 占位 deploy workflow（可选，writer 判断）
若 repo 无任何部署信号则**不建** workflow 文件（空 YAML 无消费方是死代码，违背 ponytail）；仅文档模板。若建：`.github/workflows/deploy.yml` 骨架 + `environment: production` + 五 env 注入 + 显式 TODO 注释（无 deploy 步骤，guard: workflow_dispatch only）。

### U3 issue 关闭
#164 关闭评论：代码已就绪（file:line 表）、注入契约文档路径、真实 secrets 创建推迟到部署目标确定（reopen 或新 issue 跟踪部署落地）。

## 3. 验收标准

1. 注入契约文档落盘：五值/类型/消费方/检查单/CI 边界齐全。
2. 无死代码（workflow 仅在有部署信号时建）。
3. #164 关闭，评论含对照与后续跟踪路径。

## 4. 实施顺序

U1（+U2 判定）→ commit 不 push → `/tmp/cgc_2046-writer22-report.md`；U3 合并后执行。可与 021 并行（零文件交集）。

## 5. Assumptions

1. `docs/运维/` 目录存在或创建（writer 按 repo docs 结构定，无则并入 `docs/`）。
2. 无既有部署信号（vercel/fly/docker 等 config）——writer grep 确认；有则 U2 改为真实接线并回报。
