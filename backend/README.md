# Cgc2046 Backend

CGC 平台后端：Elixir / Phoenix / Ash Framework，对外暴露 GraphQL（ash_graphql）与 MCP server（anubis_mcp）。架构范式（BYO：网站 = 业务中枢 + MCP server，用户自带 OpenClacky 做 Agent 执行）见仓库根 [CONTEXT.md](../CONTEXT.md) §0。

## 快速启动

```bash
mix setup    # deps.get + ecto.create/migrate + seeds（幂等：默认工作台 2046 + 五角色 + 三份协议定义）
mix phx.server
```

- 本地 Postgres 16，默认凭据 `postgres/postgres@localhost`（见 `config/dev.exs`）；可选 `cp .env.example .env && direnv allow`（`.envrc` 已接好，变量清单见 [.env.example](.env.example)）。
- **种子必跑**：没有默认工作台 `2046` 时，新用户注册会静默降级不入座（`sign_in_flow.ex` 记 warning 后继续）——服务一切正常、工作台面全空。

## 本仓必经步骤（与通用 Phoenix 教程不同）

- 改 Ash 资源后：`mix ash.codegen <name>` 生成迁移，再 `mix ash_postgres.generate_migrations --snapshots-only` 同步 snapshot（CI `--check` 门禁；活表加索引自带 concurrently 纪律，见 `AGENTS.md`）。
- 改权限/角色能力或错误码后：`mix cgc2046.gen_rbac_contract` / `mix cgc2046.gen_error_codes_contract` 再生成契约工件（CI `--check`）。
- 新增 Hex 依赖：过许可证门禁（AGPL-3.0 兼容，CI `mix cgc2046.check_licenses`），规则见 `docs/开源合规/依赖引入规则.md`。

## 验证

```bash
mix precommit   # compile --warnings-as-errors + deps.unlock --unused + format + 全量测试
```

CI 门禁清单以 `.github/workflows/ci.yml` backend job 为准（format → compile → rbac 契约 → 错误码契约 → license → snapshot → hex.audit → test）。

## 部署

GitHub Actions（`.github/workflows/deploy.yml`）：mix release + TCR 预编译 deps 镜像 + Kamal。运维手册见 `docs/运维/`；deps 镜像节奏见根 [AGENTS.md](../AGENTS.md)「Deploy deps 镜像节奏」。

## 领域与约定

- 领域术语单一事实源：根 [CONTEXT.md](../CONTEXT.md)
- 架构决策：[docs/adr/](../docs/adr/)
- 贡献流程与 CI gate 细节：[CONTRIBUTING.md](../CONTRIBUTING.md)
- backend 专属约定：[backend/AGENTS.md](AGENTS.md)
