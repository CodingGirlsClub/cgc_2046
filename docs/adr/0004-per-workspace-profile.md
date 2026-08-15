# ADR-0004: Profile / Theme 移植为 per-workspace 租户资源

> 日期：2026-08-08 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（方伯）+ Leader
> 关联：CONTEXT.md §8（Profile 定义为租户资源）、workflows/research/2026-08-08-settings-workspace-scoped-profile.md、workflows/plans/2026-08-08-per-workspace-profile.md
> 触发：Settings 子页面多租户隔离诊断——"Personal"组（个人资料 / Preferences）当前为全局数据，与领域模型"Profile = 租户资源"声明不符。

---

## 背景（Context）

- 多租户设计以 workspace_id 无状态 scope 为核心（ADR-0003「现有架构保留项」）；全库 11 个业务资源均带 `multitenancy workspace_id`。
- 唯一偏差：Profile 字段（头像/简介/技能/visibility）与主题偏好（ui_theme_preference）挂在全局 `users` 表；`portfolio_items` 仅 `user_id`、无租户维度，moduledoc 明写"非租户隔离"。
- 但 CONTEXT.md §8 早已声明：**Profile（成员公开资料，租户资源）**——头像、简介、标签（含 Portfolio 作品展示）；"二期需要聚合展示时再拆"。
- 前端 Settings 侧栏已按 Linear 式分组 Personal / Workspace，但 Personal 组 URL 挂在 `/w/[slug]/settings/account/*` 下，操作的是全局数据——URL 暗示租户隔离、数据却是全局，语义错位。
- 新用户注册不自动加入任何 workspace，per-workspace 化后无归属 workspace 则无 profile 编辑上下文。

## 决策（Decision）

1. **Profile 移植为 per-workspace 租户资源**：新建 `WorkspaceProfile`（workspace_id + user_id + avatar_url/location/about/skills/visibility/ui_theme_preference），multitenancy by workspace_id，identity `(workspace_id, user_id)` 唯一。
2. **字段范围**：头像 / 简介 / 技能 / Portfolio per-workspace；`display_name` / `email` 保留全局身份字段（不改）。
3. **主题偏好 per-workspace**：`ui_theme_preference` 迁入 WorkspaceProfile（用户决策），前端 localStorage 按 workspace 隔离。
4. **PortfolioItem 加租户维度**：补 `workspace_id` + multitenancy，纠正"全库唯一无租户维度业务资源"。
5. **User 收窄为全局身份**：保留 email/display_name/is_platform_admin/member_number/joined_at；移除 avatar_url/location/about/skills/visibility/ui_theme_preference（Phase 5 删除表列，遵 AGENTS.md 不保留向后兼容）。
6. **visibility=:workspace 语义收窄**：从"同任一工作区成员可读"（shared_workspace_ids）改为"目标 workspace 成员可读"（该 WorkspaceProfile 所属 workspace 的成员）。
7. **默认 workspace "2046"**：迁移幂等创建 slug=`2046`、join_policy=`open` 的默认社区 workspace（当时 seed 六角色）；新用户注册自动加入（当时 member 角色），存量无 membership 用户回填加入。保证"注册即可用"、全局入口有兜底归属。**已被 ADR-0006 取代：注册入 2046 改为无标签 membership，`member` 角色退役。**
8. **全局入口下线**：`/settings/account/profile` 删除，访问 redirect 到 `/w/2046/settings/account/profile`；`profileHref()` 无 slug fallback 到 2046。

### 拒绝的替代

- **profile 字段挂 workspace_memberships**：成员资格变动会级联影响档案生命周期；受邀未加入/申请中无 membership。
- **全局数据 + per-workspace 覆盖层**：两层模型复杂度高，与 CONTEXT.md 已声明的租户资源方向不符。
- **主题保持全局**：用户已决策 per-workspace（与 profile 一致，URL 语义对齐）。

## 后果（Consequences）

- **正面**：领域模型与实现一致；Settings Personal 组真正租户隔离；新用户有默认归属；PortfolioItem 不再是无租户维度的例外。
- **代价/风险**：
  - 回填数据膨胀（profile/portfolio 复制到 user 所有 membership 的 workspace）——per-workspace 模型固有，dev 早期接受。
  - visibility 语义收窄可能改变存量用户可见性——新表新语义，默认 only_me 隐私优先。
  - ThemeProvider 需感知当前 workspace（SSR/hydration 沿用首帧 dark + 客户端异步应用模式）。
  - 迁移属 Data/service 级：需回滚演练 + signoff。
  - 默认 workspace 2046 无平台管理员时 owner 缺失（角色仍 seed），后续首个平台管理员可认领。
  - `workspace_profiles.workspace_id/user_id` 与 `portfolio_items.workspace_id` 未加 FK 约束（沿用全库其它租户表同风格，无 references()）；删除 user/workspace 不会级联清理 profile/portfolio，留孤儿行。ADR-0004 让 profile 数据量翻倍，孤儿成本升高，FK 留待数据规模上来后单独决策。

## 决策依赖

- ADR-0003（多租户设计保留项：workspace_id 无状态 scope）
- CONTEXT.md §8（Profile 租户资源声明）
- workflows/plans/2026-08-08-per-workspace-profile.md（实施分阶段）
