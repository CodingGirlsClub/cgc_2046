# ADR-0014: slug 公开 URL 段不可变——draft 可改、发布后锁死

> 日期：2026-09-16 ｜ 状态：**已接受（Accepted，补记）** ｜ 决策者：用户（product owner）
> 关联：#619（三资源 code 对齐，本 ADR 随其落地）、#588 / #604（Initiative 侧先行）、#453（Event/Course 锁定实施）、#447（slug identity）、#241（错误码契约四清单）
> 触发：Event/Course 的 slug 锁定是无 code 裸 `add_error`（落 GraphQL 只有 `invalid_attribute`、两端无文案），与 Initiative #588/#604 的稳定 code 待遇分叉；且口径此前只存在于代码注释与本地 `plans/006`（improve skill 本地产物，不入库），缺权威决策记录。

---

## 背景（Context）

- slug 是公开路由段：`/events/[slug]`、`/courses/[slug]`、`/initiatives/[slug]`，**全局唯一**（唯一索引 + Ash identity，无 workspace 前缀），游客可读、进 sitemap 动态条目。
- 发布后链接即进入分发渠道：微信分享 scheme、邀请邮件内嵌 URL、社群粘贴、搜索收录——改名 ⇒ 全部已分发链接即刻 404，无重定向无历史。
- Event/Course 锁定 2026-09-08 拍板实施（#453）；Initiative 2026-09-15 对齐语义并率先带稳定 code（#588 `initiative_slug_locked`、#604 `initiative_slug_taken`）。

## 决策（Decision）

1. **公开 URL 段即契约**：slug 发布后不可改。draft 随便改；非 draft（open / closed / cancelled）一律锁死——守卫写 `status != :draft`（白名单反向），未来新增状态**默认受锁**。
2. **无 rename 后门**：不提供 rename action、slug 历史表、301 重定向（与 Event 终态不可逆、恢复 = 新建同款语义）。
3. **三资源一致口径**：Event / Course / Initiative 同一锁定语义、同一错误面形状。
4. **错误面走 #241 契约**：锁定与撞 slug 均为 `BusinessError` 稳定 code，命名法 `<resource>_<reason>`（`event_slug_locked` / `event_slug_taken` / `course_slug_*` / `initiative_slug_*`）——资源前缀是规范（契约 100+ code 零资源无关先例；i18n key = code，共码必共文案会丢资源语境）。
5. **锁定优先于格式错**：格式校验是资源级 validation 带 `only_when_valid?: true`——非 draft 传「又非法又锁定」的 slug 只回一个 `*_slug_locked`，不叠加格式错把人骗进「改好格式再来」的死循环（#588 先行论证）。
6. **撞 slug 的转换走 error_handler 按唯一索引名分派**（`events_slug_index` / `courses_slug_index`，`ConstraintConflict.constraint_named?/2`）：fail-closed，未来新增其他唯一索引不会被误吞成 `slug_taken`（Event 缴费 CHECK 分派同款纪律）。

### 拒绝的替代

- **统一资源无关 code `slug_locked`/`slug_taken`**：违反 `<resource>_<reason>` 命名法与全仓惯例；i18n key = code，共用 code 必须共用一份文案（丢「活动/课程/倡导活动」语境）；且需给 Initiative 破坏性改名（契约、web zh/en、小程序、多处测试），零用户价值。
- **slug 历史表 + `get_by_slug` 兜底旧 slug 并 301**：v1 明确不做（plans/006 审计估 M-L）；出现真实改名需求再立项，不预埋。
- **rename 专用 action**：同上——锁死即锁死，恢复路径 = 新建。

## 后果（Consequences）

- **正面**：三资源错误面对齐，前端/MCP 可按 code 精确查文案；slug 格式校验从 create/update 双份内联 change 收敛为资源级单源 validation。
- **代价/风险**：
  - `BusinessError` 信封无 value 通道：被拒新值不再进错误结构体——「参数丢失 vs 锁定拦截」的排障区分改由 code 本身承担（请求侧本就自带原值）。
  - 非 draft 传「又非法又锁定」的 slug 从两个错误变为单个 `*_slug_locked`（行为微调，对齐 #588 既有语义）。
  - 显式传空字符串 `""` 的 slug 从静默放过变为格式拒绝（match validation 比原内联 change 更严，属收紧）。
- **历史注记**：本 ADR 为补记——Event/Course 语义 2026-09-08 已生效（#453），Initiative 2026-09-15（#588/#604），#619 补齐 Event/Course 稳定 code 并将本 ADR 确立为三资源口径的权威出处（`plans/` 目录是 improve skill 的本地工作产物，经 `.git/info/exclude` 有意不入库，不构成仓内引用）。
