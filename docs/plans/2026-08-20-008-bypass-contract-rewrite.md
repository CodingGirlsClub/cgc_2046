# Plan 2026-08-20-008 · #217：改写 bypass_reads.ex「唯一原始 SQL 出口」假契约为真实规则

## 背景

`backend/lib/cgc_2046/accounts/bypass_reads.ex` moduledoc :3 声称本模块是「**唯一允许原始 SQL 的出口**」，与事实不符（scout 2026-08-20 HEAD 全量取证）：

- 手写 resolver `authorize?: false` 旁路 = **14 处**（issue 旧 12 处行号全部失效，HEAD 新增 2 处）；
- 全库原始 SQL = **61 处 / 21 文件**（issue 声称 40+，低估）；
- moduledoc :19-21 自述 `shared_workspace_ids/1` 已退役，但 CONTEXT.md:93 词条仍把它写成现状且缺 `owner_count/1`。

风险非漏洞而是**假契约误导**：后续 agent 按假规则写码（错误拒绝合法模式 / 在新处开旁路无人知鉴权归属）。

## 决策（scout 推荐路线）

- **中央契约改写**：bypass_reads.ex moduledoc 重写为真实规则——本模块 = 仅「聚合读逃生舱」（member_count/1 + owner_count/1 + 平铺展示字段契约）；其余原始 SQL 六类分布各归其主；resolver 旁路按处门禁纪律。
- **就近注释**（项目既有惯例，非集中清单）：14 处 resolver 每处上方补安全注释，表述真实前置门禁，沿用 issue/ADR 编号引用惯例。
- **纯注释/doc 线**：零行为变更，测试零改动。
- MCP 工具面措辞注意：0 原始 SQL（全 Ash authorize?: false 直读），moduledoc 分类不得写成「原始 SQL」，避免制造第二个虚假断言。

## 实施单元

### U1 bypass_reads.ex moduledoc 重写（:2-27）

1. 删「唯一允许原始 SQL 的出口」断言；改为：本模块 = 聚合读逃生舱（member_count/owner_count + 平铺字段），2026-08-02 ③ 收敛遗产。
2. 新增「全库旁路与原始 SQL 真实分布」段（中央契约）：
   - resolver `authorize?: false` 14 处（graphql_schema.ex，按处门禁纪律——每处须注释真实前置门禁）；
   - 原始 SQL 六类：resource action 内部（policy/状态机守卫后条件 SQL）35 / 认证域 helper（凭证/验证码/票据）13 / 通知 4 / worker 无 actor 3 / 基础设施事务锁 2 / workflow 存储/幂等 2。
3. **quirk 知识段（:17-26）原样保留**（aggregate 被读 policy 过滤的根因、exists/2 不叠加 policy、LEFT JOIN 平铺——多处旁注引用此段，动即断链）。
4. 措辞先例对齐 `membership_context.ex:23`（「鉴权由调用方判定语义负责」）。

### U2 graphql_schema.ex 14 处就近注释

每处 `authorize?: false` 上方注释「真实前置门禁」（按 scout 分类）：

| 类 | 处（HEAD 行号） | 注释要点 |
|---|---|---|
| A token 定位 | :891 admit_member_by_token、:2130 token_credential_fetch/3 | 凭证即凭据：sha256 哈希精确匹配 + 双因子，nil 塌缩 invalid_token |
| B action 层授权 | :1274 save_speaker_materials、:1298 complete_speaker_invitation | get 后 for_update 带 actor 走 action policy（Speaker 本人/Owner-Admin 兜底） |
| C 公开显式判定 | :2325 resolve_course_map | resolver 显式 status==open && visibility==public 否则 nil |
| D 工具层授权/本人锚 | :2398/:2408/:2515/:2572/:2583/:2645/:2655/:2663 | LearnerAuthorization 前置 / user_id==actor.id / membership 门槛 + ToolCallLog 读 policy 为 platform_admin 专属故旁路 |
| E 管理员计数 | :2907 load_membership_counts | count aggregate 会被 read policy 过滤（BypassReads 已知 quirk），platform_admin 面 |

勿误标：:932/:2119/:2502（注释提及）、:2961（authorize?: true）非旁路点。

### U3 CONTEXT.md :93 词条同步

重写「旁路读取面（BypassReads）」：去「唯一出口」断言、删 stale `shared_workspace_ids/1`、补 `owner_count/1`、指向 moduledoc 真实分布；带新日期标注（沿用既有惯例）。

## 验收标准

1. backend：`mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` 全绿（bypass_reads_test.exs 零改动通过 = 行为零变更证明）。
2. 14 处注释逐一覆盖 scout 清单；全库 grep `authorize?: false` 在 graphql_schema.ex 恰 14 处命中（新注释不含该字面量以免污染计数——注释措辞用「旁路读取」表述）。
3. CONTEXT.md:93 不再含 shared_workspace_ids 现状表述。

## 非目标

- 零行为变更：不改任何 authorize 语义/validation/重构（红线）。
- 不消灭旁路点（14 处均为已验证安全的既定模式，只补文档）。
- 不动 61 处原始 SQL 本体（各归其主，仅中央契约记分布）。
- 不动 membership_context.ex / mcp 等其他文件的既有注释。

## 风险

| 风险 | 缓解 |
|---|---|
| 行号漂移（issue 旧 12 处全失效） | U2 以 HEAD 14 处为准；writer 实施时 re-grep 校验 |
| quirk 段误删 → 下游旁注断链 | U1.3 明示原样保留 |
| 注释含 `authorize?: false` 字面量 → 污染 grep 计数 | U2 措辞纪律：注释用「旁路读取」不写字面量 |
| CONTEXT.md 与 #215 线同文件异区 | 合入串行（后线 rebase），文本无冲突 |

## 关联

- Issue #217；Scout 报告 `agent://Scout217`（2026-08-20，HEAD 全量取证）
- 引用本 moduledoc 的旁注：workspace.ex:114-116、workspace_membership.ex:67-68、member_count.ex:5-8、read_workspace_profile_by_visibility.ex:15-16（不改，验证不断链）
- 后续：解锁 #219 权限签核包（本线是其 blocker）
