# E-5 公开面缺口补齐:readiness 第三项 + visibility 报名校验 + workspace 报名入口 + 测试补面

> 日期:2026-08-15 · 来源:issue #50 + scout 静态探查(E5Scout,HEAD b30d6e3)· 状态:自治流水线批准
> 关键事实:公开面主体(发现页/宿主页/报名表单/赞助入口/token 着陆页/双主题)已在 develop 落地;本 PR 只补 scout 确认的 5 缺口。

## 缺口清单(scout 证据)

| # | 缺口 | 证据 |
|---|---|---|
| G1 | **安全洞**:createEnrollment 的 eligible_target 只查 status='open'+deadline,不校验 visibility——非成员可经 API 报名 workspace-only 活动 | enrollment.ex:392-401 |
| G2 | readiness 清单第三项(sponsorship_enabled 时 tiers 已配)未实现,注释自认「待 E-3 落库后追加」,E-3 已落地 | readiness.ex:10-11,26-33 |
| G3 | workspace 详情页无报名入口,workspace-only 活动 UI 无报名路径(AC 明文) | offering-pages.tsx 详情页 |
| G4 | 前端 public-offerings.ts/公开页组件与 PUBLIC_*/CREATE_ENROLLMENT 契约零测试 | web/lib |
| G5 | 后端 getEventBySlug/getCourseBySlug 无 GraphQL 层测试 | graphql_schema |

## 锁定决策

| # | 决策 |
|---|---|
| D1 | G1 修复:eligible_target SQL 加 visibility 校验——公开报名(status=open AND visibility=public);workspace-only 活动的报名走成员路径(见 D2),非成员对 workspace-only 报名 = not_found(与匿名读同语义,不泄露存在性)。**行为变化声明**:此前非成员可 API 报名 workspace-only,视为漏洞修复 |
| D2 | G3:offering-pages.tsx 详情页(workspace 内,成员已可见)加报名入口——成员对 workspace-only/open 活动可报名,复用 submitEnrollment 数据层(它走 createEnrollment mutation,鉴权后端管);入口显示逻辑:活动 open + 当前用户无既有 enrollment |
| D3 | G2:readiness.evaluate 加第三项 `:sponsorship_tiers_configured`(event.sponsorship_enabled=true 时 tiers 非空已配;course 恒 pass);清單注释删除;graphql offeringReadiness 返回形状不变(items 加一项) |
| D4 | G4/G5 测试补面:后端 get_by_slug 匿名/登录/404 三态 + readiness 三项正反例;前端 public-offerings 数据层 + 组件渲染(结构断言优先,按 AGENTS.md e2e 分层)——具体形状 writer 按 repo 既有测试模式定,不为凑数写空测 |
| D5 | 不动:白名单/读策略/field_policies(E-11 已测)、token 着陆页(已测)、赞助表单(E-3 已测)、双主题(全局 Provider 适用) |
| D6 | 流程纪律:writer 本地全套自查后 **commit 不 push**,报告;advisor01 评本地 commit;PASS 后 push 开 PR → CI → 合并 |

## 影响面

- backend:enrollment.ex(eligible_target +1 条件)、readiness.ex(+1 项)、graphql 无需改(payload 不变形)
- web:offering-pages.tsx(报名入口)、(+测试文件)
- 测试:后端 +slug/readiness 用例;前端 +公开面测试

## 阶段与验收

1. G1 visibility 校验 + 负向测试(非成员 workspace-only 报名→not_found;成员→ok)
2. G2 readiness 第三项 + 正反例(enabled+tiers 空缺→warning;配好→pass)
3. G3 workspace 详情页报名入口 + e2e 断言
4. G4/G5 测试补面
5. 全量 mix test ×2 seeds + pnpm typecheck/lint/test/build + format/compile
6. 验收 = issue #50 AC 全勾:匿名白名单(已有测试)、报名落库、赞助两级+token 页(已有)、readiness 三项可查、双主题;G1 修复后非成员报名被拒

## 风险与回滚

- G1 修的是安全洞,存量数据可能有非成员对 workspace-only 的 enrollment——扫描一遍,若有,报告数量不自动删(用户决策)
- D2 成员报名入口与既有 enrollment 唯一性约束交互——UI 层防重(已有 submitState 模式复用)
- 回滚:单 PR revert

## signoff 标准

- advisor01 check PASS + hard stops 0 + advisory 无必修 → push → CI 绿 → 合并;关 #50

## 人类决策记录

- 2026-08-15 用户选「先 E-5 再 E-6」;scout 证实主体已落地,本 PR 为缺口补齐;G1 按漏洞修复处理
