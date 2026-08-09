# 小程序改进审计与实施方案

由 `improve` 技能于 2026-08-09 生成。审计对象是分支
`feature/wechat_mp` 在 merge-base `cf880204` 之后新增的 `miniprogram/`
全部内容、`.github/workflows/ci.yml` 的 `miniprogram` job，以及
`docs/合规上架/`；方案基于 commit `f1fd4aa`。

执行者应按下表顺序读取对应方案，严格遵守每份方案的 STOP 条件，并在完成后更新状态。
`plans/` 已被仓库 SOP 占用，因此本批只使用 `advisor-plans/`。

## 审计边界与验证基线

- 本次是 standard、只读审计；没有修改任何源码、配置、锁文件或构建产物。
- 审计开始和结束时，工作树中唯一既有改动均为
  `miniprogram/project.config.json` 的本地项目标识配置；其值未写入任何 finding 或方案。
- 只读验证通过：`pnpm typecheck`、`pnpm test:unit`（当前 5 条）、
  `pnpm check:licenses`、对既有 `dist/tt`/`dist/xhs` 执行的
  `pnpm check:diversion`，以及 `tsc --noEmit --strict true`。
- `pnpm audit --prod --audit-level high` 返回 12 个告警；全树审计返回 35 个告警。
  这些结果需要 reachability/upstream 分析，不能等同于小程序运行时可利用。
- 未审计 backend/web 的既有实现、真实平台凭据、开发者工具运行时、真机网络和平台后台配置；
  真实后端与全自动 E2E 的外部阻塞已由 GitHub issue #99 跟踪。

## 执行顺序与状态

| Plan | 标题 | Priority | Effort | Depends on | Status |
|---|---|---|---|---|---|
| [001](./001-license-gate-fail-closed.md) | 让许可证门禁按白名单 fail-closed | P1 | M | human 先裁定现有 Zlib 声明 | DONE |
| [002](./002-diversion-gate-fail-closed.md) | 让零导流产物门禁真实、完整且 fail-closed | P1 | S | — | DONE |
| [003](./003-add-toutiao-project-config.md) | 补齐抖音工程配置并隔离本机项目标识 | P1 | S | — | DONE |
| [004](./004-establish-api-contract-tests.md) | 建立 API/认证边界自动化测试 | P1 | M | 001, 002 | DONE |
| [005](./005-make-auth-state-atomic.md) | 让认证状态提交原子化并隔离账号本地数据 | P1 | M | 004 | DONE |

状态值：`TODO`、`IN PROGRESS`、`DONE`、`BLOCKED（附一行原因）`、
`REJECTED（附一行理由）`。

## Vetted findings

“杠杆”综合影响、工作量、修复风险与置信度。Direction 项单列在后面，不与缺陷排序。

| ID | 类别 | Finding 与证据 | 影响 | Effort | 修复风险 | 置信度 | 杠杆 | 方案 |
|---|---|---|---|---|---|---|---|---|
| F01 | security / deps | 持续规则要求白名单并对未列项先决策：`docs/开源合规/依赖引入规则.md:13-20,49-53`；许可证脚本却只有 blacklist，任意非空未知声明会通过：`miniprogram/scripts/check-licenses.mjs:20-28,53-70,121-128`；CI 把它当硬门：`.github/workflows/ci.yml:97`。 | `UNLICENSED`、无效 SPDX 或未获准许可证可得到绿色合规结论。 | M | MED | HIGH | 极高 | 001 |
| F02 | correctness / compliance | Unicode 解码调用不存在的 JS 方法，缺目录或零文件也成功，且只扫 JS：`miniprogram/scripts/check-no-diversion.mjs:17-30,35-50`；CI 信任该结果：`.github/workflows/ci.yml:103-105`。 | 转义禁词或非 JS 产物可绕过零导流红线，门禁产生 false green。 | S | MED | HIGH | 极高 | 002 |
| F03 | security | 401 只清 token/Workspace 状态，通知和最近报名是全局 key，退出也不清邀请 scene：`miniprogram/src/api/client.ts:41-49`、`miniprogram/src/api/real.ts:72,103-110,201-211`、`miniprogram/src/app.tsx:7-12`、`miniprogram/src/pages/join/index.tsx:10-33`。 | 换号或 token 失效后可能读取前一账号的本地通知，下一账号还可能消费遗留邀请凭据。 | M | MED | HIGH | 极高 | 005 |
| F04 | correctness / security | 登录 cookie 在 HTTP/GraphQL/data 校验前落盘，随后 session hydration 失败也不回滚：`miniprogram/src/api/client.ts:91-113`、`miniprogram/src/api/real.ts:183-199`、`miniprogram/src/pages/login/index.tsx:18-32`。 | UI 可显示登录失败，但设备已切换 token；携 cookie 的普通 GraphQL 错误还会把失败响应的 token 持久化。 | M | MED | HIGH | 高 | 005 |
| F05 | correctness | 邀请 scene 只在 `useLaunch` 处理，没有前台恢复入口：`miniprogram/src/app.tsx:2,7-13`；真机合同未限定必须冷启动：`miniprogram/e2e/REAL_DEVICE_CHECKLIST.md:42-47`。 | 小程序驻留后台时再次扫码可能不保存 scene、不进入确认页。 | S | MED | HIGH | 高 | — |
| F06 | security / correctness | 审批查询不含申请人/目标展示字段，mapper 丢弃 `userId`，UI 一律写“新的报名申请”，未知 kind 会落入加入审批：`miniprogram/src/api/operations.ts:89-98`、`miniprogram/src/api/real.ts:159-167,288-305`、`miniprogram/src/pages/workspace/index.tsx:115-126`。 | 审批人无法区分同工作台多条申请，且可能把授予 Workspace 访问权误当报名确认。 | M | MED | HIGH | 高 | — |
| F07 | correctness | 提交后把报名写入单例 storage 并携带 route id，但结果页完全忽略 id：`miniprogram/src/pages/register-form/index.tsx:66-67`、`miniprogram/src/pages/enrollment-result/index.tsx:11-16`。 | 直接打开或回退到旧结果 URL 时可展示另一条、已过期的报名收据。 | S | LOW | HIGH | 高 | — |
| F08 | performance | 报名链路重复拉取宽 `Session`；“我的报名”串行 Session→列表，发现页每次显示并发重拉：`miniprogram/src/pages/event-detail/index.tsx:37-46`、`miniprogram/src/pages/register-form/index.tsx:23-41`、`miniprogram/src/api/real.ts:138-180,214-255`、`miniprogram/src/pages/discover/index.tsx:23-37`。 | 移动网络下增加详情到 mutation 的固定往返和首屏等待，并反复传输未消费字段。 | M | MED | HIGH | 高 | — |
| F09 | tests | 现有唯一 unit 文件只覆盖纯格式化；cookie、401、GraphQL errors、空 data 等均无测试，Node strip-types 还无法导入参数属性：`miniprogram/tests/domain.test.ts:3-43`、`miniprogram/src/api/client.ts:21-113`、`miniprogram/package.json:18`。 | 认证/请求失败合同回归时，当前 unit 与 mock E2E 仍可全绿。 | M | LOW | HIGH | 极高（基础设施） | 004 |
| F10 | tests | E2E 只有微信 mock happy path，CI 不跑交互；三端条件分支仅靠编译与人工清单：`miniprogram/e2e/journey.e2e.mjs:44-82`、`miniprogram/src/app.config.ts:1-52`、`miniprogram/src/platform/index.ts:17-57`、`.github/workflows/ci.yml:98-104`。 | 表单错误、订阅拒绝、邀请恢复、平台裁剪等分支可在 PR 中静默破坏。 | M | LOW | HIGH | 高 | — |
| F11 | tech-debt / DX | codegen 覆盖两个受跟踪文件，但 CI 生成后不检查 diff：`miniprogram/codegen.yml:3-18`、`miniprogram/package.json:13,19`、`.github/workflows/ci.yml:94-102`。 | 提交中的 generated 类型可以过期，而 CI 用临时重生成结果通过。 | S | LOW | HIGH | 高 | — |
| F12 | dependencies | `graphql-request` 仅被 type-import，`react-dom` 无消费方，却都是 runtime dependency：`miniprogram/package.json:38-41`、`miniprogram/src/api/client.ts:2`、`miniprogram/src/api/mockTransport.ts:1`。 | 扩大安装、许可证和升级表面，并误导维护者理解真实传输层。 | S | LOW | HIGH | 中 | — |
| F13 | dependencies / security | Taro 4.2.1 固定引入 `swiper@11.1.15`：`miniprogram/pnpm-lock.yaml:8363-8374`；锁文件还保留弃用构建链：`miniprogram/pnpm-lock.yaml:2885-2887,3660-3673,3930-3932`。 | 审计报告生产树 1 个 critical、全树 3 critical/11 high；但当前上游最新版仍受影响且小程序运行时 reachability 未证实。 | L | HIGH | MED | 中（先调查） | — |
| F14 | correctness / DX | 仓库缺少 Taro 抖音专用 `project.tt.json`，清单却让抖音工具替换微信配置；私有配置 ignore 规则还错误地匹配目录：`miniprogram/e2e/DOUYIN_REDNOTE_CHECKLIST.md:5-10`、`miniprogram/project.config.json:2,14`、`miniprogram/.gitignore:7`。 | 抖音工具会打开微信产物，且本机项目标识容易污染受跟踪配置。 | S | MED | HIGH | 极高 | 003 |
| F15 | DX / correctness | 缺发布 endpoint 时无条件回落 localhost，模板与 E2E mock 也没有 release gate：`miniprogram/config/index.ts:4-5,23-46`、`miniprogram/.env.example:1-14`、`miniprogram/package.json:7-9`。 | 可成功上传指向 localhost 或启用 mock/缺模板的“发布”包。 | S | MED | HIGH | 高 | — |
| F16 | DX | 本地 `check:ci` 只做 codegen/typecheck/微信构建，真实 CI 还做许可证、单测、三端构建与导流门禁；Node/pnpm 也只在 workflow 固定：`miniprogram/package.json:1-20`、`.github/workflows/ci.yml:85-104`。 | 本地命令成功不代表 PR gate 成功，Node 漂移还会改变实验性 TS runner 行为。 | S | LOW | HIGH | 高 | — |
| F17 | docs / security | 隐私草案只列手机号与登录凭据，实际强制收集并持久化姓名、邮箱、自由文本原因：`docs/合规上架/隐私指引草案.md:7-18`、`miniprogram/src/pages/register-form/index.tsx:93,102-108`、`miniprogram/src/api/real.ts:239-246`。 | 上架披露与真实数据流不一致，尤其遗漏自由文本用途、可见范围与保留规则。 | S | LOW | HIGH | 高 | — |
| F18 | docs | ICP 清单中的主体限制、价格、平台数量与审核时窗没有官方来源、核验日期或 owner：`docs/合规上架/ICP备案材料清单.md:3-5,13-29,37-46`。 | 平台政策变化后无法追溯结论，可能按过期资料准备预算和排期。 | S | LOW | HIGH | 中 | — |

## Direction 选项（不与缺陷排序）

| ID | 方向 | 证据与收益 | Effort | 风险/取舍 | 置信度 |
|---|---|---|---|---|---|
| D01 | 完成隐私页、客服/申诉与账号生命周期 | 草案明确仍缺正式隐私政策和申诉渠道，当前登录页只有不可打开的同意文案：`docs/合规上架/隐私指引草案.md:32-46`、`miniprogram/src/pages/login/index.tsx:62-65`。先交付可读隐私页与客服入口；注销需另做 Workspace owner 交接和留存设计。 | L（隐私页本身 S） | HIGH；不能把退出登录包装成注销。 | HIGH |
| D02 | 建立最小、第一方、无手机号的报名漏斗度量 | 详情→登录→报名→结果→订阅已有稳定事件边界：`miniprogram/src/pages/event-detail/index.tsx:37-50,101-104`、`miniprogram/src/pages/login/index.tsx:14-35`、`miniprogram/src/pages/enrollment-result/index.tsx:21-35`。可据此比较三端摩擦点。 | M | MED；埋点本身要过隐私和许可证门，不先加第三方 SDK。 | HIGH |
| D03 | 在微信端增加原生分享入口 | 活动详情已具备公开内容与报名 CTA，启动链路已能接 scene：`miniprogram/src/pages/event-detail/index.tsx:56-105`、`miniprogram/src/app.tsx:7-12`。先做微信活动卡片/深链，裁剪端只采用各自平台原生挂载。 | M | MED；严守抖音/小红书零跨端导流，不抽象成伪统一分享 API。 | HIGH |
| D04 | 设计活动签到而不是复用 Workspace 邀请凭据 | 已有扫码 UI 和一次性 scene 消费链路：`miniprogram/src/pages/profile/index.tsx:73-79`、`miniprogram/src/pages/join/index.tsx:27-45`。可把 Enrollment 延伸到真实到场。 | L | HIGH；需专属凭据、权限、幂等、弱网与审计，不能复用 Workspace scene。 | HIGH |

## 依赖说明

- 001 必须先由 human 决定现有 `pako@1.0.11` 的 `MIT AND Zlib` 声明如何落入持续规则；
  未裁定前不得偷偷加例外，也不得声称许可证门禁已经修好。
- 002 与 003 可独立执行，也可在 001 等待期间并行。
- 004 会新增 MIT 的 Vitest，但其全传递树必须由完成后的 001 验证；它也复用 002 纳入
  `test:unit` 的 fixture 文件，因此依赖 001、002。
- 005 依赖 004 提供可隔离的 Taro/API fault-injection 测试；先锁定合同，再改认证提交时机。

## Findings considered and rejected

- D4 “零对话/执行 UI”、裁剪端零导流、v1 不引入 UI 组件库均为明确产品红线，不是 finding。
- 真机 cookie 提取、`getPhoneNumber code` backend 契约、本地通知中心、
  `workspaceName = "公开工作台"`、手机号明文存储均按用户给出的已知限制/已决风险接受；
  F03 只讨论跨账号隔离，不否定“通知本地存储”的决策。
- Workspace “批次码”与 Event/Course `InviteBatch` 语义存在计划文本冲突；当前 checklist 已明确没有独立
  Workspace batch mutation。本批不把报名批次码误接到 `admitMemberByToken`，产品若坚持该能力应先设计
  `WorkspaceInvitationBatch`。
- `check-graphql.mjs` 遇到非预期 HTTP 仍给 warning，是它“只校验契约结构、不证明连通性”的显式边界，未报 bug。
- `ApprovalSummary.kind` 对未来第三种 kind 的 fallthrough 已并入 F06；当前后端只承诺 Enrollment/JoinRequest，
  没有把假设中的 Sponsorship 当成当前生产故障。
- 依赖 audit 告警没有直接生成升级方案：当前 Taro/automator 最新可用版本未解除主要链路，且未证明
  `swiper` 浏览器实现进入小程序产物；禁止用 overrides 盲压传递版本。
- 真实后端与全自动 E2E 的凭据、HTTPS、平台后台前置由 issue #99 跟踪，不在本批重复规划。
