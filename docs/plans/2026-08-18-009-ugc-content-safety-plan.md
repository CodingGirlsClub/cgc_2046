# UGC 内容安全接入：报名 reason 提交链路 msgSecCheck 同步拦截（issue #230）

> 来源：issue #230（D-24-C）+ 本计划 research 修正（见「风险评估修正」）。
> 状态：待人工批准（sop plan mode）
> 日期：2026-08-18

## 目标

给小程序报名表单的自由文本 `reason`（≤300 字，`register-form/index.tsx:146`）接入微信内容安全同步检查（SDK `WeChat.MiniProgram.Security.msg_check/2`）：**违规内容拒绝提交**（明确错误码 + 前端精确文案），平台侧瞬时故障放行并留 telemetry——建立「有内容安全机制」的合规事实，为未来审批面展示 reason（第一批 F06 方向）铺路。

### 风险评估修正（research 发现，2026-08-18 核实）

原 issue 定性「上架合规硬缺口」需修正：**reason 当前无任何展示面**——审批 GraphQL 对象 `pending_approval`（graphql_schema.ex:1187-1203）只暴露 requester_name/workspace_name/context_title 等元数据，web participations 页与小程序 workspace 审批卡均不渲染 submission_payload。reason 是「只存不展示」的一对一批审材料（类表单收集，非公开 UGC）。

微信上架审核对内容安全的强制要求主要针对**对其他用户公开展示**的 UGC（评论/社区/弹幕类目）。故本项定位：
1. **防御性合规**（审核员抽检用户输入类小程序时「有机制」优于「无机制」；privacy 指引草案 §2 已声明 reason 用途）
2. **展示面前置条件**（F06 若做审批面展示 reason，内容安全必须先行——展示即公开 UGC）

优先级维持 P2（上架前做，非即时阻断）。

### Out of scope

- tt/xhs 内容安全 API 接入（各自平台审核独立于微信；SDK 无覆盖，接入需新调研+可能新依赖——留各自真机联调期 Phase 4，本计划显式 pass-through 并注记）
- name/email 字段检查（name 非公开展示面——requester_name 展示链路 writer 核实来源，若确认来自 displayName 属另一自由文本面，记录 RISKS 不扩本计划）
- 审批面展示 reason（F06 方向，独立产品决策）
- 图片/媒体检测（img_check/media_check_async——无图片上传面）
- 隐私指引文档修订（reason 用途披露已存在，检查机制不改变收集范围）

## Current-state 证据（2026-08-18 develop 核实）

- **提交链路**：`miniprogram/src/pages/register-form/index.tsx:146`（Textarea maxlength=300，必填）→ `real.ts:285`（createEnrollment mutation）→ `backend/lib/cgc_2046/events/enrollment.ex:75`（`submission_payload` map attribute）——reason 是 payload 内自由文本字段，服务端无长度/内容校验（长度靠前端 maxlength，非服务端约束）
- **SDK 能力**：`WeChat.MiniProgram.Security.msg_check/2`（deps/wechat/.../security.ex:75-84）——POST /wxa/msg_sec_check，body `%{content: text}`；频率限制官方 4000 次/分钟、200 万次/天（报名 QPS 远低于此）；违规判定在响应 errcode/label（87014 = content risky）
- **WechatClient 宿主**：`backend/lib/cgc_2046/miniprogram/wechat_client.ex` 已就绪（PR #220/#224 建立）——msg_check 走同宿主，access_token 自动管理
- **errcode 保真先例**：`client.ex` 的 `{:platform_rejected, code, msg}` 模式（PR #220 建立）
- **BusinessError 先例**：`Cgc2046.Errors.BusinessError`（code 形如 `<resource>_<reason>` snake_case，经 AshGraphql 映射，前端按 code 精确查文案——`miniprogram/src/domain/error-copy.ts` / `web/lib/payment-errors.ts`）
- **展示面缺失**（本计划 research）：`pending_approval` 对象无 submission_payload 字段；web/app/participations/page.tsx 零 reason 渲染；小程序 workspace 审批卡无 payload
- **测试基建**：Tesla.Mock 模式（notification_service_test.exs 现行写法，全 URL 匹配 + mock fun 内断言请求体）

## 设计

| 决策 | 方案 | 理由 |
|---|---|---|
| 检查时机 | **提交时同步拦截**（enrollment create 的 before_action 链） | msgSecCheck 是同步 API（~百 ms 级）；报名频率低（非评论流）；违规当场拒绝 + 前端文案，用户体验与合规双满足；异步+状态标记（存后检查+标记 hidden）复杂度高且「先展示后隐藏」有窗口 |
| 违规语义 | **fail-closed on violation**：errcode 87014 / risky label → `BusinessError code: "enrollment_content_rejected"`，提交被拒 | 合规核心语义：违规内容不落库 |
| 故障语义 | **fail-open on infra error**：网络错误/限流/5xx/未知 errcode → 放行 + `:telemetry.execute` 计数（事件 `[:cgc_2046, :content_check, :skipped]`，metadata 仅含 reason 类别原子，**不含 reason 明文**） | 可用性优先：平台瞬时故障不应阻断报名（审核要求「有机制」，瞬时放行可接受且业界通行）；fail-closed 于 infra 会把微信抖动变成报名全断 |
| 范围 | **v1 wechat-only**：`Client.content_check(:wechat, content)` 实现；tt/xhs 显式子句返回 `{:ok, :unchecked}`（各自上架独立审核，Phase 4 接入） | 最小面；不引入无消费方的抽象（单一实现不做 Provider behaviour——AGENTS.md 反投机抽象） |
| 检查字段 | **reason only** | 唯一长自由文本；name 短且展示链路待核实（writer 确认 requester_name 来源，如属 displayName 自由文本面记 RISKS 留后续） |

**拒绝的替代**：
- 三平台同步接入——tt/xhs SDK 无覆盖，需新调研 + 可能违反 license gate，且各自审核独立（微信审核只审 weapp 产物）
- Provider behaviour 抽象（payments 模式）——单一实现 + 平台语义差异大，过早抽象；facade 单函数够用（未来 tt/xhs 接入时再评估提升）
- 异步检查 + 状态标记——复杂度（新状态字段 + 展示过滤 + 重试 worker）远超收益；且「先落后审」存在违规内容已入库窗口

### 安全与红线

- **reason 明文不进日志**（fail-open telemetry 只记类别原子；BusinessError message 用通用文案不含原文）
- msg_check 请求体含 reason 明文——走 WechatRequester（`debug: false` 已定，PR #224 F2 红线沿用）
- content_check 函数对 content 做 2500 字节截断保护（官方上限，防超长报错）——reason ≤300 字天然满足，防御性 clamp
- 幂等：纯读检查（POST 但无副作用语义），重试安全

## 影响面

- 后端修改：`backend/lib/cgc_2046/miniprogram/client.ex`（+`content_check/2` 公开函数 + wechat 实现与错误分类）；`backend/lib/cgc_2046/events/enrollment.ex`（create :enroll action 挂 before_action 检查，违规 add BusinessError）
- 后端测试：`backend/test/cgc_2046/miniprogram/client_test.exs` 或就近文件（content_check：通过/违规 87014/限流 45009 放行/网络错误放行——Tesla.Mock 四例）；`backend/test/cgc_2046/events/enrollment_test.exs`（create 集成：违规拒绝 + payload 不落库 / 通过正常创建 / tt 平台跳过检查）
- 前端修改：`miniprogram/src/domain/error-copy.ts`（+`enrollment_content_rejected` 精确文案，如「提交内容未通过安全检查，请修改后重试」）
- 文档：CONTEXT.md（内容安全词条：检查点/失败语义/范围）；隐私指引草案可选补一句「提交内容经平台安全检查」（不改变收集范围，改动最小化——由 writer 判断是否必要，不必要则 RISKS 注记）
- 无数据库变更、无新依赖、无迁移

## Phases（测试先行）

### P1 content_check facade（后端）
测试先行（Tesla.Mock）：通过（errcode 0）→ `{:ok, :passed}`；违规（87014）→ `{:error, {:content_rejected, 87014}}`；限流（45009）/网络错误/非 200 → `{:ok, :skipped}`（fail-open 语义，含 telemetry execute 断言——`:telemetry_test` attach 或 Reattach）；tt/xhs → `{:ok, :unchecked}` 零外呼（Tesla.Mock 无匹配即抛错的结构性证明）。
实现：`Client.content_check(platform, content)`——wechat 分支走 `WechatClient.fetch()` + `Security.msg_check`；错误分类三分支；content 2500 字节 clamp。
验证：目标测试文件全绿（先红后绿：模块函数未实现时红）。

### P2 enrollment create 挂检查（后端）
测试先行：enrollment_test 补三例——违规 reason 的 create 返回 `enrollment_content_rejected` BusinessError 且**不创建行**（Repo 计数断言）；正常 reason 创建成功（回归）；tt actor（或 ctx 平台标记——按 create action 实际平台来源实现，writer 核实 platform 在 enrollment 链路的可得性：若 create 时无 platform 信息，取 actor 的 user_identities 平台或 ctx 传入；不可得则 RISKS 记录并默认 wechat-only 检查——tt/xhs 本就 pass-through，语义等价）。
实现：`enrollment.ex` create :enroll 的 before_action（或 change）里调 `Client.content_check`，违规 `add_domain_error`（BusinessError code `enrollment_content_rejected`，对齐 enrollment.ex 现有 add_domain_error 模式）。
验证：enrollment_test 全绿 + 全量回归。

### P3 前端文案 + 收尾
`error-copy.ts` 加 `enrollment_content_rejected` →「提交内容未通过安全检查，请修改后重试」（无平台字样，零导流）；CONTEXT.md 词条；全量自查（backend compile/format/test ×2 seeds；miniprogram typecheck/test:unit/build 三端/check:diversion）。

## 检查与回滚

- 功能验证：P1/P2 测试红→绿轨迹；违规内容全链路拒绝（前端文案可见）
- 安全：请求日志红线（WechatRequester debug:false 既有）；telemetry 无明文；违规内容不落库（P2 断言）
- 回滚：纯增量（一函数 + 一 before_action + 文案词条）——git revert 单 PR 可回；回滚后回到无检查状态（合规降级，可接受）
- 并发：检查在 before_action（事务前），无并发面

## Signoff criteria

- P1/P2 红→绿轨迹记录；全量 mix test ×2 seeds 绿；前端三端构建 + 零导流门禁零命中
- 违规 reason 端到端拒绝（BusinessError code 前端可精确匹配）
- PR 独立评审 PASS 后合并；PR body 注记「tt/xhs pass-through 待 Phase 4」

## 待人工决策（批准即按推荐）

- **D-1 范围**：v1 wechat-only + tt/xhs 显式 `{:ok, :unchecked}` pass-through（推荐）vs 三平台同步（不推荐：新调研/依赖/独立审核域）
- **D-2 故障语义**：infra 错误 fail-open + telemetry（推荐）vs fail-closed（不推荐：微信抖动 → 报名全断）
- **D-3 优先级定位确认**：接受「防御性合规 + 展示面前置」定性（非上架硬阻断）——影响排期弹性，不改实施内容
