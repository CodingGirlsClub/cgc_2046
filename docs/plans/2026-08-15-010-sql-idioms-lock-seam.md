# SQL 微惯用语:advisory-lock seam 收拢 + uuid dump 帮手

> 日期:2026-08-15 · 来源:架构评审(report 1786689868)候选⑥ + scout 静态探查(PoisedPenguin,HEAD 46f502a)· 状态:自治流水线批准
> 范围纪律:**只收锁 + uuid**;domain_error 族(39 错误原子仅共享 1 个,假同构)不收;各资源裸 SQL 本体不动(ADR-0005 条件 UPDATE 不变量)。

## 目标

1. 两处内联 advisory 锁(sponsorship.ex:450 / miniprogram_code.ex:166)收进 `Repo.acquire_lock!/2`——获得 lock_timeout 5s + deadlock 友好错误映射(纯行为增益,现两处均无 timeout 无错误映射,死锁时裸抛 Postgres 错误)。
2. uuid dump 帮手收敛:5 个私有 `uuid!` + 3 处族外内联 `Ecto.UUID.dump!` → `Repo.uuid!/1` 单点。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | `Repo.acquire_lock!(key, opts \\ [])`:现有 `acquire_workspace_lock!/1`(22-40:SET lock_timeout '5s' + pg_advisory_xact_lock + lock_not_available/deadlock_detected 映射)泛化;opts: `hash: :hashtext \| :hashtextextended`(默认 :hashtext 保持现调用方域不变);**两处内联各自传原 hash 函数,键域零变化**(miniprogram_code 现用 hashtextextended($1,0),若误换 hashtext 会与 workspace 锁域碰撞/漂移) |
| D2 | `acquire_workspace_lock!/1` 保留为 acquire_lock! 的薄包装或直接改调用方三处(membership assign_roles 等)——writer 依 diff 最小原则选择,不留双入口若调用方全迁 |
| D3 | `Repo.uuid!/1` = `Ecto.UUID.dump!/1` 包装(值校验 + 明确错误);收敛:enrollment.ex:633 / sponsorship.ex:793 / speaker_invitation.ex:836 / sponsorship_delivery.ex:147 / notification_consent.ex(根目录版):93 五私有帮手删除;event.ex:492 / course.ex:457 / invite_batch.ex:160-162 三处内联 dump 改调;注意 notification_consent 有两个同名文件(根目录裸 SQL 版 vs miniprogram/ Ash 版),只动前者 |
| D4 | **domain_error 族不收**(scout:39 错误原子仅 :target_tenant_mismatch 跨资源共享且文案各异,假同构);speaker_invitation 已有 query_count/2 私有先例,不强推;PR body 记录该判定 |
| D5 | 行为变化声明(唯一有意):两处内联锁获得 lock_timeout 5s + 死锁/超时友好错误——之前死锁裸抛 Postgres %DBConnection.Error,现映射为领域可读错误;正常路径(拿到锁)零变化 |
| D6 | 测试:既有全部零改动(sponsorship_concurrency_test 17-73 穿过内联锁、membership_test 250-273 穿过 workspace 锁,双证据);Repo 层新增单测:两种 hash 域各自加锁成功/重复加锁幂等(同事务)——锁超时路径难测不硬测,注释说明 |

## 当前状态证据(scout PoisedPenguin)

- repo.ex:22-40 完整形状(lock_timeout + hashtext + 双错误映射);两处内联均无 timeout 无映射
- uuid 族:5 私有 + 3 内联 = 8 处;speaker_invitation 另有 query_count 帮手(不扩散)
- 测试面:并发/竞态测试直接穿锁路径,零改动即证据;全仓无 lock_timeout UX 断言(新增映射不碰旧测试)

## 影响面

- **改**:repo.ex(+acquire_lock!/uuid! 两函数)、sponsorship.ex、miniprogram_code.ex、enrollment.ex、speaker_invitation.ex、sponsorship_delivery.ex、notification_consent.ex、event.ex、course.ex、invite_batch.ex(机械替换)
- 测试:+repo 层单测,其余零改动
- 数据库/配置:无

## 阶段与验收

1. Repo.acquire_lock!/uuid! + 单测(双 hash 域/幂等/uuid 校验)
2. 锁收拢(sponsorship/miniprogram_code 各传原 hash)→ 两并发测试绿
3. uuid 八处机械替换 → 全量绿
4. 全量 `mix test` ×2 seeds + format + `compile --warnings-as-errors`
5. 验收:grep uuid! 私有帮手零残留、Ecto.UUID.dump! 内联零残留(除 Repo.uuid! 内部);既有测试零改动

## 风险与回滚

- hash 域错配(见 D1)——单测双域分离守护
- 锁收拢后 miniprogram_code 锁语义变化(超时会等 5s 而非无限等):现无超时 = 死等,新行为 5s 后友好错误——纯增益方向
- 回滚:单 PR revert

## signoff 标准

- advisor01 check PASS + hard stops 0 + advisory 无必修 → 常设规则合并

## 人类决策记录

- 2026-08-15 用户夜间授权自治流水线;scout 三子项判定(锁收/uuid 收/adapter 不收)依证据采纳
