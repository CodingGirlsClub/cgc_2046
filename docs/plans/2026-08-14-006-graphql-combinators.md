# graphql_schema 组合子抽取:三个薄门控收敛错误契约

> 日期:2026-08-14 · 来源:架构评审(report 1786689868)候选③ + scout 静态探查(AppallingSkink,行号 HEAD 8c3f047)· 状态:自治流水线批准(用户夜间授权)
> 范围纪律:只抽私有组合子收敛重复骨架;**不推翻 #96 手写 resolver 决定,不迁回 AshGraphql managed mutations**;错误契约逐字保留(最紧红线:mcp_token not_found 契约测试)。

## 目标

沿文件内 admin_list 先例(工厂函数 + 门控单点 + 错误映射闭包)抽三个薄私有组合子,把错误契约从 26 个散点门收敛为单点——直接消灭 5 次错误通道 bug(125c7a6/f9b77c5/f2f9a81/9c3a638/d959e91,scout 已核实全部同构:手写 resolver 的错误序列化偏离标准协议)的复发面。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | 三组合子全部 `defp` 私有于 graphql_schema.ex(参照 admin_list 先例,不建新模块) |
| D2 | `with_actor(context, fun)` 标准门:nil→`unauthorized_error()`,ok→`fun.(actor)`;`with_actor(context, fun, on_nil: fn ctx -> ... end)` 唯一消费方 me(auth_uncertain 分支语义红线,graphql_auth_test L189/250 守护) |
| D3 | **顺手统一 2 处 string 漂移门**:permission_matrix(L24)/offering_readiness(L50)的 `{:error, "unauthorized"}` → `unauthorized_error()`——scout 证实全仓无 code 断言,测试不可见;这是错误协议归一,本 plan 授权 |
| D4 | `token_credential_fetch(resource, token, extra_filter \\ :none)`:hash(sha256 hex lower,空/非 binary→`{:error, :invalid_token}`)→ `token_hash == ^hash` 定位 `read_one(authorize?: false)` → nil 塌缩 invalid_token。流①(accept_invitation)以 `extra_filter: [id: id]` 调用保留双因子,not_found 语义由调用方在 `:invalid_token` 上映射回 accept_not_found_errors;流②(decide)替换 speaker_token_hash + fetch_speaker_invitation 两 helper,tenant 取自定位到的 record 不变 |
| D5 | `scoped_update(actor, resource, tenant_id, action, attrs, context)`:read-first(`filter(user_id == ^actor.id)` + `read_one(tenant:, actor:)`)→ `{:ok, nil}` 分支错误单点(workspace_profile_not_found)→ `for_update(action, attrs)` → `Ash.update(tenant:, actor:)`;to_ash_graphql_errors 第 4 参显式透传 resource。消费方:update_workspace_profile(:update_profile, map_input 全量)/set_theme_theme(:set_ui_theme, 单字段) |
| D6 | **不适合套清单(保持手写)**:sign_in/sign_up/sign_in_with_platform(无 actor 门)/me(on_nil 特判)/admit_member_by_token(cond 多条件错误优先级)/create_speaker_invitation(with 链错误优先序 invalid_input>unauthorized)/save_speaker_materials + complete_speaker_invitation(get-by-id 非 user_id 形状,with_actor 门可套 body 一次性——writer 自行判断,套了必须语义逐字等价)/promote_demote(已 with_admin,避免两层门)/decide_speaker_invitation(已是组合子雏形,只变薄调用 token_credential_fetch) |
| D7 | 错误契约红线:mcp_token_test L269-323 的 not_found(message "could not be found" + fields ["id"])与 invalid_attribute(fields ["revoked_at"])精确值**逐字不动**;accept/speaker payload 错误形状不动 |
| D8 | 测试零改动:全部既有 graphql 测试原样通过即重构正确性证据;**不新增测试**(纯收敛无新契约;唯一新单点是私有 defp,由既有契约测试守护) |

## 当前状态证据(scout AppallingSkink,HEAD 8c3f047)

- 26 门点:21 case(19 标准 + 2 string 漂移)+ 2 cond + 2 with + 1 with_admin
- token 流两份逐行 diff 出 7 项真差异(hash 来源/双因子/tenant/action 参数化/not-found 形状),组合子只收共同骨架,差异留调用方
- owner 域两份仅 2 处真差异(action atom + attrs 范围)
- admin_list 先例(7 消费方)证明工厂化=错误契约单点,5 bug 全落在其外的手写区
- 净删估算 ~95-115 行(5-6%),41 次改动热点区的重复骨架

## 影响面

- **只改一个文件**:backend/lib/cgc_2046_web/graphql_schema.ex(净删 ~100 行,新增 3 defp ~25 行)
- 测试/数据库/配置:零改动
- CONTEXT.md:不新增词条(私有组合子是文件内部结构,非领域概念)

## 阶段与验收

1. with_actor 抽取 + 19 标准门迁移 + me 的 on_nil + 2 处 string 门统一 → 匿名 unauthorized 测试全绿
2. token_credential_fetch + 流①②迁移 → accept/speaker 测试全绿(零改动)
3. scoped_update + owner 域两处迁移 → profile/theme 测试全绿
4. 全量 `mix test` ×2 seeds + format + `compile --warnings-as-errors`
5. 验收:既有 graphql 测试零改动全绿;grep 证明 21 处 `case context[:actor]` 标准门残留为 0(除 D6 清单);净删行数落在 80-130 区间

## 风险与回滚

- 流① not_found 映射若错装在 invalid_token 上会把双因子不匹配静默变 invalid_token——accept_invitation_test L145/155 的 code "not_found" 断言守护
- me 的 on_nil 误用默认门会丢 auth_uncertain——graphql_auth_test 守护
- 回滚:单文件单 PR revert 即可

## signoff 标准

- advisor01 check 评审 PASS + hard stops 0 + advisory 无必修 → 按常设规则合并
- 全量测试绿 + format/compile 干净

## 人类决策记录

- 2026-08-14 用户夜间授权:③④⑤⑥⑦ 依流水线自治执行,advisor01 PASS 即合并,不再请示
