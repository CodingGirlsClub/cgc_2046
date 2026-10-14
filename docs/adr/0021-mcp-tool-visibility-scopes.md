---
status: accepted
date: 2026-10-03
---

# ADR-0021：MCP 工具列表按调用者角色分层暴露（scopes）

> 日期：2026-10-03 ｜ 状态：**已接受（Accepted）**

`/mcp` 是全平台唯一的 MCP server（ADR-0001 D6），100 个工具全部注册在 `Cgc2046.Mcp.Server`，此前 `tools/list` 不按用户过滤：任何持连接 token 的学员都能看到 `admin_promote_user`、`refund_order` 这类管理 / 教研工具的名称、描述与参数结构。`tools/call` 一直是安全的——Wrapper 的 membership 门、工具层角色判定、审计对每次调用生效，越权调用只会收到 `forbidden`。所以这不是越权漏洞，而是**暴露面过大**：内部业务模型与权限流程写在工具描述里等于一份地图；学员 agent 被 prompt injection 诱导后会去试管理类工具，防线只有 Wrapper 一道；每个会话把全部工具 schema（约 2.8 万 token）塞进学员 agent 的 context，而学员只用得到其中 32 个（约 0.9 万 token）。

决定走 anubis_mcp 2.0.0 原生的组件 `scopes`：工具经 `use Anubis.Server.Component, type: :tool, scopes: [...]` 声明所属可见层，anubis 的 `tools/list` 隐藏 scope 不够的工具、`tools/call` 同样拒绝，判据是 `frame.context.auth.scopes`。分四层，scope 名沿用 `get_role_playbook` 的角色名：全员可见（`scopes: []`，34 个）、`tutor`（4 个）、`workspace_admin`（34 个）、`platform_admin`（28 个）——精确名单以 `test/support/mcp_tool_tiers.ex` 为钉死事实源（2026-10-05 勘误：原文写 32/6，与代码差异 2，四条合计仍 100）。scope 由 `Cgc2046.Mcp.Scopes` 在每个请求按 `current_user` 跨工作台并集重算：tutor = 任一工作台持 tutor / owner / admin；workspace_admin = 任一工作台持 owner / admin；平台管理员级联拿全部三层（可见面与分层前一致，不回退，也解决了 `delete_course` / `delete_event`「Owner ∪ 平台管理员」——anubis 要求所列 scope 全部满足，表达不了「或」）。每请求重算意味着角色变更下一个请求即生效，不存会话状态（D12）。

**分类原则：可见面不比授权更严**——只要某类用户有可能被授权调用，就不对他隐藏，所以本次分层不让任何人失去现有权限。授权偏宽的 5 个工具（`create_invitation` volunteer 可发邀请、`list_event_moderators` 主理人可读、审核三件套未指定 reviewer 时任何成员）仍全员可见；是否收窄授权在 #1084 跟踪，收窄时 scope 与授权放同一个 PR 改。**scope 是粗检查，不替代授权**：Wrapper、工具层、数据层 policy 全部保留，scope 只回答「这个人在任何工作台有没有可能用到这类工具」，具体到哪个工作台仍由 Wrapper 判定。

注入点是 `Server.handle_request/2`（`tools/list` 与非 task 增强的 `tools/call` 的唯一入口）：Server 在 `use Anubis.Server` **之后**挂 `@before_compile Cgc2046.Mcp.Scopes`，钩子把 scope 注入 `frame.context.auth` 再 `super`。必须晚于 `use`：anubis 在自己的 `__before_compile__` 里才定义 `handle_request/2`，在模块正文里直接覆写拿不到 `super`（实测编译失败 `no super defined`）。失败方向均为 fail-closed：钩子缺失 → 带 scope 的工具对所有人隐藏；成员资格读取失败 → `granted/1` 返回 `[]`；工具漏标 → 全员可见（anubis 默认），由 `test/support/mcp_tool_tiers.ex` 的精确名单加 `tool_scopes_test` 钉死，新增工具必须显式归层。

被 scope 拒绝的调用在 anubis 层就返回，到不了 `Wrapper.run/4`，不补写就丢审计（违反 D6「每次工具调用 = 审计记录」）。钩子把 anubis 的 `insufficient_scope` 译成 `forbidden: <tool> requires <角色>`（现有工具描述向 agent 承诺过「没权限时错误以 forbidden 开头」，也不外发 `granted` 的 scope 命名），并经 `Wrapper.record_denied/4` 补写 forbidden 审计。服务端不声明 `listChanged`、不推送：被降级的人调用会被拒，被升级的人需重连才能看到新工具，三份非学员 playbook 已写明「角色变更后请重连 MCP」。

否决的路线：

- **打开 anubis 的 OAuth `authorization:` 配置**：要授权服务器地址（我们没有）、校验 `aud`、校验函数拿不到请求，还会让每个请求校验两次 token。
- **拆成多个 endpoint**（`/mcp` vs `/mcp/admin`）：多角色用户要装多个 URL，工具注册要维护两份。仅当需要网络层隔离时才值得。
- **只过滤 `tools/list`、不拦 `tools/call`**：隐藏不是授权，agent 仍可按名调用；anubis 的 scopes 两边都做，且这一层之后仍有 Wrapper。
- **把 scope 放进 `meta:`**：`meta` 会作为 `_meta` 序列化给客户端（GLOSSARY.md「meta 载体纪律」），`scopes` 不会。
- **token 级 scope**（生成 token 时选「学习用 / 管理用」）：可叠加在本方案之上的加固，有「管理员 token 泄露」的真实担忧再做。

残余风险：task 增强的 `tools/call`（`Session.Tasks`）直接走 `Handlers.handle`，不经 `Server.handle_request/2`，会绕过钩子——Server 当前只声明 `tools` capability，该路径不可达，`tool_scopes_test` 钉住不得声明 `tasks`，将来启用时必须把注入点下沉。`submit_prep_for_check` / `submit_prep_quality_report` 的工具层只判「被指派者 ∨ 管理角色」、不复查 tutor 角色：被指派后失去 tutor 角色的人会被 scope 挡住，接受——内容读写工具本就要求 `Rbac.staff?`，他们已无法做任何有意义的起草。钩子依赖 `__before_compile__` + `defoverridable handle_request/2` 的行为，升级 `anubis_mcp` 时靠 `mcp_tool_visibility_test` 兜底。每个 `tools/list` / `tools/call` 多一次成员资格查询，与 Wrapper 现有成本同量级。回滚：还原单个 PR，无迁移、无数据变更、无依赖变更。
