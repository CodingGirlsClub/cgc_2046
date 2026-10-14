---
status: accepted
date: 2026-10-01
---

# ADR-0020：小程序上传前用线上部署的 schema 校验全部 operation

> 日期：2026-10-01 ｜ 状态：**已接受（Accepted）**

小程序发版走微信审核（数小时到数天），在 deploy 流水线之外，已发布版本不能即时回收。GraphQL 先校验后执行：「新小程序 + 旧后端」下，operation 里只要有一个后端尚未部署的字段，整条 document 就被拒（如 capsule 主 query 加一个 additive 字段，走廊整页挂）。web 由 `web` job 的 `needs: backend` 结构性保证先后顺序，小程序此前只靠「提审前人工确认 backend 已部署」的惯例。

决定走路线 B「上传门」：上传前用**线上实际部署的后端 schema** 校验 `src/api/operations.ts` 的全部 operation，任一不兼容即拒绝上传（`pnpm check:release-schema`，见 `miniprogram/README.md` 发版流程）。后端 `/healthz` 以 `x-cgc-version` 头回传 Kamal 注入的 `KAMAL_VERSION`（`<sha>-pb<hash>`），脚本据此取得线上 SHA，再 `git show <sha>:backend/priv/graphql/schema.graphql`，不改 deploy 流水线。门 fail-closed：请求失败、缺头、SHA 解析失败、git 失败、任一校验错误都 exit 1。后端 deploy 失败时 kamal-proxy 不切流，healthz 仍报旧 SHA，校验自然失败，无需额外处理。

否决的路线：

- **A：拆独立 fail-soft query**。「易变字段」靠主观判断，请求数增加，且只保护 capsule，其余 operation 仍裸奔。
- **C：运行时能力协商**。依赖 introspection，与 VULN-001（#81，prod 拒绝 introspection）冲突，并会破坏 codegen 类型。
- `@include(if:)` 之类的条件字段救不回来：未知字段在校验阶段就被拒，根本到不了执行阶段。

残余风险：小程序上传（通过门）之后，有人手动回滚后端，新版小程序遇到旧 schema 仍会整条 query 被拒。这是低频的人工操作，处置是**回滚后端前**用目标版本预检：`pnpm check:release-schema --ref <回滚目标 SHA>`；红则先别回滚，或同步回退小程序。另一个前提：线上必须已部署带 `x-cgc-version` 头的后端，否则默认模式 fail-closed（预期行为，不是故障）。

不进 `check:ci`：依赖线上网络状态，会让无关 PR 因线上状态变红，理由同 `check-release-endpoint.mjs`。与根 `AGENTS.md`「后端 API 收紧 × 客户端依赖」互为两个方向：那条管后端收紧先于客户端过审，本条管客户端依赖后端新字段。
