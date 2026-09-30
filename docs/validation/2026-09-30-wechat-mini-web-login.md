# Web 经微信小程序确认登录：本地验收报告

日期：2026-09-30。范围依据：[实施方案](../plans/2026-09-30-1206-feat-wechat-mini-web-login-plan.md)、[ADR-0019](../adr/0019-wechat-mini-program-web-login.md)。

结论：实现和本地功能验证完成；**尚不具备生产 Web 入口切换条件**。小程序完整 `check:ci` 被既有依赖漏洞审计阻挡；正式配置、主域隔离及真机矩阵尚未验收。本报告不代表发布批准。

## 交付边界

- 基线：`d61cceb975b3957890016af6516bcbf18452ca4c`。
- R1：`07af99bf`，后端交接能力、小程序确认页、契约、方案及 ADR。
- R2：本报告所在提交，Web 新入口、轮询恢复与文案。
- 继续按已验证手机号复用 User；不创建无手机号账号，不合并历史账号，不迁移报名、订单、角色或学习数据。
- 微信外部接口在自动化验证中使用 stub；没有使用生产账号、发送真实短信或消耗真实手机号额度。
- 未 push、创建 PR、生产迁移、部署或上传小程序。

## 已执行的检查

日志名为本次执行产生的本机临时证据，不是 CI 附件；临时目录清理后需按命令重跑。所有命令在对应端目录运行。

| 检查 | 结果 | 证据文件名 |
| --- | --- | --- |
| Backend `mix precommit` | 3366 passed，1 skipped | `cgc-mini-web-committed-precommit.log` |
| Backend 两个新增测试文件 | 16 passed（13 HTTP + 3 微信启动接口） | `cgc-mini-web-candidate-backend.log`；最终以全量 precommit 覆盖为准 |
| Ash snapshot freshness | `mix ash_postgres.generate_migrations --check` exit 0 | `cgc-mini-web-committed-schema-check.log` |
| 新表迁移 down/up | 隔离测试库成功回滚再迁移；index/FK 守卫通过 | `cgc-mini-web-down.log`，全量 precommit |
| Web 全量 Vitest | 165 files，1690 passed | `cgc-mini-web-web-release.log` |
| Web 新入口定向测试 | 10 passed | `cgc-mini-web-web-touch-check.log` |
| Web typecheck / lint | 类型通过；lint 0 errors、6 条未改文件既有 warnings | `cgc-mini-web-web-types-last.log`、`cgc-mini-web-web-lint-last.log` |
| Web Next production build | Node 24 构建成功 | `cgc-mini-web-web-build-final.log` |
| 小程序 codegen freshness | `pnpm codegen` 和 `git diff --exit-code -- src/api/generated` exit 0 | `cgc-mini-web-codegen-final.log` |
| 小程序类型、单测 | 类型通过；node:test 380 passed，Vitest 232 passed / 12 files | `cgc-mini-web-mp-types-final.log`、`cgc-mini-web-mp-tests-release.log` |
| 小程序 weapp / tt / xhs 构建 | 三端通过；既有 CSS 顺序与 webpack size warnings | `cgc-mini-web-weapp-restored.log`、`cgc-mini-web-tt-build2.log`、`cgc-mini-web-xhs-build2.log` |
| 包体积、许可、跨端守卫 | 微信主包 1,136,693 bytes，低于 1,900,000；4123 个依赖许可通过；xhs patch pairing、tt/xhs 零导流通过 | `cgc-mini-web-size-restored.log`、`cgc-mini-web-mp-licenses.log`、`cgc-mini-web-xhs-pairing.log`、`cgc-mini-web-diversion2.log` |
| mock anchors / E2E 文档对账 | 通过 | `cgc-mini-web-anchors.log`、`cgc-mini-web-e2e-docs.log` |

`check:ci` 在 audit 阶段退出；上表是各组件独立执行的结果，不能据此宣称完整命令通过。mock 验收后已恢复非 mock 的 weapp 构建。

## 认证、并发与回滚证据

HTTP 测试走真实 GraphQL/Plug、Cookie/Bearer 与隔离 PostgreSQL，只替换微信外部服务：

- 新用户经平台手机号授权后确认并领取 Web 会话；用户数量仅增加 1，默认入座成功，短信验证码表没有新增记录。
- 现有小红书用户授权相同手机号，返回同一 User ID，用户总数不变；确认后 Web 领取仍是该 User。
- 确认前不可领取；匿名、非微信身份、错误 proof 与外站 Origin 被拒绝；另一浏览器不能查询私有状态、取消或领取。
- 同一用户重复确认幂等；另一用户不能覆盖确认归属；取消、过期、刷新使旧请求不可用。
- 独立数据库连接并发消费只允许一次成功。签发过程失败注入后，旧 Web token 撤销与票据更新同时回滚。
- Web 登录不撤销微信小程序 token。消费响应丢失后的恢复必须匹配原浏览器、本次 JTI 和 User；已有其他 Web 账号不会被静默覆盖。

同号复用测试没有构造带报名、订单与角色的完整业务数据集，不能将其写成 A02 全部验收通过；这部分仍须在受控验收环境补证。新流程没有业务资源迁移或重写调用。

守卫变异分别移除 proof、期限、确认前置、确认身份不可覆盖、平台吊销范围和邀请路由隔离：每项都出现对应失败，恢复后通过。证据为 `cgc-mini-web-mut-{proof,expiry,approval,identity_immutable,platform_scope,invitation}.log` 及 `cgc-mini-web-mut-restored.log`、`cgc-mini-web-mut-invitation-restored.log`。恢复时后端 15 passed，随后新增新用户场景，最终专项 16 passed。

## 实际 UI 验证

**Web：** ego-browser 使用隔离的本地 Next 服务与真实后端同源代理，只 stub 微信外部接口。请求确认后，原网页自动回到 `/`，`me` 已认证，sessionStorage 中待登录请求清空，JavaScript 读不到认证 Cookie。另验证 375px 窄屏无横向溢出、操作控件至少 44px、手机入口 52px，未出现 hydration 错误。证据：`cgc-mini-web-browser-ready.png`、`cgc-mini-web-browser-signed-in.png`、`cgc-mini-web-browser-375.png`。

**微信开发者工具：** `node e2e/web-login.e2e.mjs` 在已登录、已就绪的项目窗口执行，使用 mock transport。`cgc-mini-web-mp-e2e6.log` 的最终结果为 `pass=true`，覆盖 explicit approval、login return、fresh request、cancel。截图：`cgc-mini-web-confirmed.jpg`、`cgc-mini-web-cancelled.jpg`。这只能证明模拟器页面操作与路由，不能证明真实微信手机号授权、正式 URL Link 或手机浏览器返回。

复跑开发工具 E2E 前先构建 `CGC_E2E_MOCK=true` 的 weapp 并打开项目，等待 runtime bridge 就绪；脚本不负责反复开窗。结束后恢复非 mock 构建。

## 未通过与未验证项

1. **依赖审计未通过。** `pnpm check:ci` 首步 `pnpm audit --prod --audit-level high` 返回 exit 1。审计摘要为 21 条漏洞：2 low、13 moderate、5 high、1 critical（其中 1 条 ignored）；显示的 high 涉及 fast-uri、webpack-dev-middleware、brace-expansion。相对基线的 package.json、pnpm-lock.yaml、pnpm-workspace.yaml 均未变化，属于现有依赖树问题。本次未改锁文件、未关闭审计，也未伪造 PR 环境来绕过检查。证据：`cgc-mini-web-mp-ci.log`。
2. **构建发布地址检查未通过。** `node scripts/check-release-endpoint.mjs weapp` 检出开发默认 localhost endpoint。当前产物仅供本地验证，不能上传；应由发布负责人使用正式配置重建，再通过该检查。未读取生产配置内容。证据：`cgc-mini-web-release-endpoint.log`。
3. **真实主域隔离未验证。** 本地同源代理通过不等于 A20 通过；还需生产等价域名下的 host-only Cookie、api 子域隔离与跨站拒绝证据。
4. **真机矩阵未验证。** 方案 §8.1 的桌面 Chrome/Safari 扫码、iOS/Android 外部浏览器、微信内网页，以及同手机号小红书用户已有业务数据均需补证。真实 AppID 权限、手机号额度、正式页发布和合法域名也尚未确认。

## 发布前交接

先处理依赖审计与正式构建配置门；后端迁移由人合并/发布，小程序确认页由人上传、审核、发布。之后在生产等价验收环境部署 R2 候选 Web，执行方案 A01/A02/A20 与全部真机矩阵，再决定是否切换生产 Web 入口。R1 与 R2 必须维持分步发布依赖，不能仅因本地测试通过而一起上线。

出现错误账号登录或跨浏览器领取时停止新入口，由人退回 Web 版本；旧入口会恢复短信依赖。回退不合并或删除用户，不自动执行生产 migration down。
