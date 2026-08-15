# ADR-0006: member 退出 Role 枚举，成员资格即 membership

> 日期：2026-08-15 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：#147 D3、#151（B2）、#161（B6）、#71（自定义角色地基）、plan `docs/plans/2026-08-15-017-refactor-member-semantics-plan.md`
> 触发：`/join open` 挂 `learner`、注册入 2046 挂 `member`，两条路径给同权普通成员挂了不同词汇；权限映射页把四个同权角色展示为四行。

---

## 背景（Context）

- 领域事实：Workspace 内所有角色本质上都是 Member。数据模型已是 `WorkspaceMembership` + `MembershipRole` 多对多。
- 病根：`Role.role_names/0` 把 `:member` 列为与 tutor/volunteer/learner 平级的第六个角色。
- 能力层早已同权：`Rbac.abilities_for/2` 对 member/tutor/volunteer/learner 仅 `view_workspace + access_invite_only`；空角色列表同样返回该基准。
- 不迁移存量 = 永久双词汇。

## 决策（Decision）

1. **`member` 退出 Role 枚举。** 成员资格 = 存在 `WorkspaceMembership`；Role 只留差异标签 `[:owner, :admin, :tutor, :volunteer, :learner]`。
2. **四条入座路径默认无标签：** `/join open`、注册入 2046、`JoinRequest.approve` 默认、Invitation 预授权空列表。
3. **成员基准能力改为「任意 membership 即有」。** 行为与旧 member 完全等价；不再经 member 角色判定。
4. **存量一次到位：** 删除全部 `name='member'` 的 MembershipRole / StepRole / Role 行。down 不恢复数据。
5. **权限映射页按「成员基准 + 差异标签」重做。** 无 member 独立行。
6. **不动：** StepAuthorization `enrolled_learner?`；owner/admin `manage_roles`；#71 自定义角色配置本身。

### 拒绝的替代

- **只改新路径、不迁存量：** 永久双词汇，权限页与徽章继续误导。
- **把 open 入座统一成 learner：** learner 有真实学习语义，不应充当「无差异默认角色」。
- **保留 member 作兼容输入：** 违反「不保留兼容层」。

## 后果（Consequences）

- **正面：** 入座词汇单一；权限页不再把同权角色画成四行；#71 自定义角色的地基铺平。
- **代价/风险：**
  - 已手配 `StepRole.allowed_roles` 含 member 的步骤会失效；当前无生产 seed，空配置 = 不限制。
  - 读到历史 member 行时属性 `one_of` 含 `retired_role_names`，迁移后库内为零。
  - ADR-0004「注册入 2046 挂 member」被本决策取代；2046 历史迁移 SQL 保持原样。
