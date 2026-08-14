# E-10 对账扫描:Reconciliation Finding + 扫描 Worker + /admin 对账页

> 日期:2026-08-15 · 来源:issue #125(用户拍板 D8)+ scout 静态探查(LexicalGrasshopper,HEAD 9b2501f)· 状态:自治流水线批准
> 附带收编:#134-① 订阅方冒烟测试、plan 003 遗留的信号 telemetry + 死信告警。

## 目标

平台级对账扫描:Oban worker 周期扫五条孤儿规则(+死信通用规则)→ 落 `reconciliation_findings` 表(刷新语义)→ /admin 对账页可读。收编订阅方冒烟测试与信号 delivery telemetry。

## 规则清单(规3 依 HEAD 修正)

| # | 规则 | 数据源(HEAD 证实) |
|---|---|---|
| 1 | confirmed enrollment 无 learning run | `workflow_runs.input_snapshot->>'enrollment_id'` join `workflow_definitions.type='learning'`,存在性判定(BYO 无平台终态) |
| 2 | pending 无 approval_deadline | 四资源 UNION(enrollment/sponsorship/join_request/workspace_application);创建路径必写,nil 即异常 |
| 3 | **修正**:active sponsorship 的 `sponsorship.active` 发布 job 处于 discarded | 原「无 signal_log」不可实现(SignalLog 只记入向,ADR-0003;会误报 100%)。修正依据:PR-A 后同事务必入队,死信=信号从未发布=原意的「信号链断连」 |
| 4 | open event/course 且 research_enabled 但 workspace 无 published research 定义 | events/courses UNION + workflow_definitions NOT EXISTS;research_enabled=false 合法不命中 |
| 5 | closed/cancelled Event/Course 仍有非终态 research run | instance key `event_<id>`/`course_<id>`(reaper 同约定)join 非终态三态 |
| 6 | 信号族死信(通用) | oban_jobs state='discarded' 且 worker ∈ {SignalPublishWorker, NotificationWorker};Pruner 7 天窗口外不判定(moduledoc 声明) |

规3 修正与规6 新增在 PR body 醒目声明(用户拍板规则的实现修正,意图保持)。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | 新 Ash 资源 `Cgc2046.Reconciliation.Finding`(表 reconciliation_findings):global?(true);字段 rule(atom 六枚举)/entity_type/entity_id/workspace_id 可空/detail(map:title/run_id/job_id/cause 等)/first_seen_at/last_seen_at;唯一索引 (rule, entity_type, entity_id);read policy 仅 PlatformAdmin(signal_log.ex 同款) |
| D2 | `Cgc2046.Workers.ReconciliationScanWorker`:queue :maintenance,max_attempts 3,unique [period: 300, states: :incomplete](expiry worker 同款);perform 逐规则扫(authorize?: false 平台读;规1/2/4/5 Ash 查询下推;规3/6 Repo 直查 oban_jobs 包读助手);**刷新语义**:命中 upsert(保 first_seen_at 更新 last_seen_at),本次未命中删除——「无孤儿→空报告」由结构保证 |
| D3 | cron 第 5 项:`*/10 * * * *`(config.exs Oban cron);不建 GIN/函数索引(现量级小表,plan 记录量涨再加) |
| D4 | GraphQL:`reconciliation_findings` field 挂 admin queries 区,复用 admin_list(过滤 rule/entity_type/workspace_id)+ with_admin 门控 + inserted_at 分页——与 list_signal_logs 同构 |
| D5 | 前端:`web/app/admin/reconciliation/page.tsx`(audit 页 adminList+typed query 模式)+ ADMIN_NAV 加「对账」;列:规则/实体/ID/workspace/首次/最近发现;规则枚举中文标签 |
| D6 | #134-① 冒烟:`signal_subscriber_smoke_test.exs`(async: false)对六应用级订阅方断言 `Process.alive?(whereis)` + `:sys.get_state().subscriptions` 非空且 pattern 集与 `Module.patterns/0` 一致——不投真信号无副作用 |
| D7 | telemetry:SignalSubscriber 骨架挂 `[:cgc2046, :signal, :deliver]`(metadata status,detail 同 NotificationFanout 事件族同构);不扩 Oban discard 插件(死信由规6 扫描发现,7 天窗口内) |
| D8 | 文档漂移修正:learning_progress_worker moduledoc「对账规则②」改为指向 #125 规则编号体系(停滞规则属未来扩展非 v1 五条) |
| D9 | 测试:worker 测试(注入孤儿→perform_job→Finding 命中;消解→再扫→消失)+ 各规则至少一例正反;Finding 资源 policy 测试(非 admin 拒);冒烟测试;前端 typecheck/lint/build(CI parity) |
| D10 | UI 验证:按 AGENTS.md e2e 分层——writer 跑通结构断言优先(admin 页渲染 + GraphQL 查询返回);若 dev 环境登录受阻,如实记录 RISKS 由 advisor01 判定 |

## 影响面

- **新建**:migrations(reconciliation_findings)+ Reconciliation.Finding + Workers.ReconciliationScanWorker + 两个测试文件 + web 对账页
- **改**:config.exs(cron 第 5 项)、graphql_schema.ex(admin query 一处)、signal_subscriber.ex(telemetry 一处)、learning_progress_worker.ex(moduledoc)、web/app/admin/layout.tsx(导航)+ web/lib/graphql/admin.ts(query)
- CONTEXT.md:增词条「对账扫描(Reconciliation Scan)」:六规则 + 刷新语义 + 死信窗口

## 阶段与验收

1. Finding 资源 + 迁移 + policy → 资源测试绿
2. ReconciliationScanWorker 六规则 + 刷新语义 → worker 测试绿(注入/消解/空)
3. GraphQL + 前端对账页 → typecheck/lint/build 绿 + 结构断言
4. 冒烟测试 + telemetry + moduledoc 修正
5. 全量 `mix test` ×2 seeds + format + `compile --warnings-as-errors`;web 全套检查
6. 验收 = issue #125 AC:注入孤儿→命中;无孤儿→空报告;/admin 可读;#134-① 断言存在

## 风险与回滚

- 规3 修正误读用户意图 → PR body 醒目声明,晨报再确认(可回退为仅规6 通用死信)
- oban_jobs 直查在测试环境需真实插 job(discard 状态 SQL 造,approval_reminder_worker_test 有先例)
- 前端登录验证受阻 → D10 兜底
- 回滚:单 PR revert + drop table

## signoff 标准

- advisor01 check PASS + hard stops 0 + advisory 无必修 → 常设规则合并;关闭 #125 与 #134(①③⑧已顺带解决,⑦遗留登记)

## 人类决策记录

- 2026-08-15 用户选「1」开工 E-10;规3 修正是技术必要(原规则 HEAD 下误报 100%),意图保持「异步链路孤儿检测」
