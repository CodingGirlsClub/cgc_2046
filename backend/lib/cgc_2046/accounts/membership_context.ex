defmodule Cgc2046.Accounts.MembershipContext do
  @moduledoc """
  「actor ↔ 工作台」成员资格数据读取的唯一归属（#2 成员资格读取收敛）。

  ## 职责

  持有全部成员资格读取形状（`WorkspaceMembership` + `load(:roles)`），供
  Rbac 判定、WorkspaceActorIsOwnerOrAdmin policy、CurrentMembershipInfo 计算字段
  委托。判定语义（roles_can? / abilities_for）不在本模块 —— 那是 Rbac 的职责；
  角色名字符串化也不在本模块 —— 那是 GraphQL 边缘（CurrentMembershipInfo）的职责。

  ## 成员资格上下文（术语）

  见 CONTEXT.md「成员资格上下文」：actor 在目标工作台（租户）的成员资格及角色
  名字（原子列表）的读取面；`role_names/2` 为 Rbac.role_names/2 的同名委托目标，
  读取实现唯一归属本模块。

  ## 错误姿态（与收敛前一致）

  - `membership_of/2`：读失败返回 `nil`（Rbac 旧行为）
  - `memberships_of_actor/1`：读失败直接抛出（CurrentMembershipInfo 旧行为，read!）
  - `owner_count/1`：读失败返回 0（BypassReads 委托，保守安全方向；与 member_count/1 一致降级）

  内部均 `authorize?: false`（读取面不做鉴权，鉴权由调用方判定语义负责）。

  ## 为什么收在这里

  Ash 升级（filter struct 形状变化）只炸本模块 + `resolve_workspace_id/1` 钉测
  （membership_context_test.exs），一处炸、一处改。

  ## 为何保留 filter struct 反向解析（已知 Ash 升级炸点，刻意不修）

  `filter_workspace_id/1` 与 `workspace_id_by_id_filter/1` 反向解析 Ash 3.31 的
  Eq / BooleanExpression / Ref struct——这是**已知技术债**，Ash 升级改 filter
  struct 形状时此处 + 钉测必炸（钉测当场失败指路，可控）。曾考虑删掉、改由调用方在
  policy 前显式注入 `workspace_id`（直读 `context[:workspace_id]`），但 research
  （`workflows/research/2026-08-05-resolve-workspace-id-ash-filter-deletion-test.md`）
  已证伪该方向的核心假设，**结论是不改**，此处记录以防后人重复研究同一死路：

  - **get-by-id 场景无法注入**：6 个 update mutation 前端只传记录 `id`
    （SDL `assignRoles(id:)` 等，schema.graphql:1518-1551），契约层面无 workspace_id
    可注入；ash_graphql update resolver 必然 get-by-id 预读（resolver.ex:1667-1837），
    预读 filter 仅 `id == ^value`。GraphQL 契约不变则该场景**必须**保留回查。
  - **list query 场景无法便宜注入**：workspace_id 在前端 GraphQL `filter` 变量里，
    Plug 层（HTTP）拿不到 GraphQL 变量；ash_graphql 无 per-query context 注入 DSL。
  - **唯一能全删的是路径 A**（前端用 HTTP header 交付 workspace_id + 新 Plug 注入），
    代价是跨前后端交付契约变更 + 跨租户/被邀请人边界处理，**代价过大，决策不取**。

  即：真正脆弱的只有 query 分支这两段；changeset 分支走 `tenant` / `get_attribute`
  / `data.id` 等稳定 Ash public API，本就不脆弱。保留现状 = 收壳点单一 + 钉测兜底。
  若未来 GraphQL 契约有变（如引入 workspace header），可重启路径 A；否则不动。
  """

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.BypassReads
  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.Accounts.WorkspaceProfile

  # 默认社区 workspace（ADR-0004 §3.5）：新用户注册自动加入（member 角色）
  @default_workspace_slug "2046"

  @doc """
  返回 actor 在目标工作台的成员资格（roles 已加载），非成员 / 匿名 / 读失败返回 `nil`。
  """
  @spec membership_of(term, String.t()) :: WorkspaceMembership.t() | nil
  def membership_of(nil, _workspace_id), do: nil

  def membership_of(actor, workspace_id) do
    case Ash.read(actor_memberships_query(actor), authorize?: false, tenant: workspace_id) do
      {:ok, [membership | _]} ->
        membership

      {:ok, []} ->
        nil

      {:error, error} ->
        Logger.error("[MembershipContext] membership_of DB read failed: #{inspect(error)}")
        nil
    end
  end

  @doc """
  返回 actor 在目标工作台的角色名列表（多角色并集，按 membership.roles 加载顺序）。

  - actor 只需含 `:id` 字段（assign_roles grant scope 校验可用 `%{id: user_id}` map 传 target）
  - 非成员 / 匿名返回 `[]`
  """
  @spec role_names(term, String.t()) :: [atom]
  def role_names(actor, workspace_id) do
    case membership_of(actor, workspace_id) do
      nil -> []
      membership -> Enum.map(membership.roles, & &1.name)
    end
  end

  @doc """
  返回 actor 的全部成员资格（跨租户 global 读，roles 已加载）。

  供 CurrentMembershipInfo 计算字段按 workspace_id 分组使用；读失败抛出
  （read!，与计算字段旧行为一致）。
  """
  @spec memberships_of_actor(term) :: [WorkspaceMembership.t()]
  def memberships_of_actor(actor) do
    Ash.read!(actor_memberships_query(actor), authorize?: false)
  end

  @doc """
  返回目标工作台当前持有 owner 角色的成员数（按 membership 去重，一人多角色只算 1 次）。

  委托 BypassReads.owner_count/1（raw COUNT，不经 membership read policy）。
  DB 失败直接抛（与 member_count/1 一致；不再吞错返 0）。
  """
  @spec owner_count(String.t()) :: non_neg_integer
  def owner_count(workspace_id), do: BypassReads.owner_count(workspace_id)

  @doc """
  从 policy context 解析目标工作台 id（#2 AST 提取收拢，三场景行为与收敛前一致）。

  ## 场景

  1. changeset（update / assign_roles）：`changeset.tenant` 或 changeset 上的 workspace_id
  2. list query（成员列表）：tenant 可能为空（global 查询），从 filter 提取 workspace_id
  3. get-by-id（GraphQL update mutation 先读目标记录）：filter 只有 id，
     按 query.resource 动态决定读哪个资源（WorkspaceMembership / JoinRequest /
     Invitation / Workspace），读出记录后取其 workspace_id。曾硬编码
     WorkspaceMembership 导致 approveJoinRequest 等 JoinRequest/Invitation 的
     get-by-id 预读用错资源查不到 → policy 误拒（已修）；Workspace 无
     workspace_id 属性，其 id 即 workspace_id（#88，与场景 4 同语义），
     新增其它无 workspace_id 的全局资源时需在此同步处理。
  4. changeset 目标即 Workspace 资源自身（#78 update_workspace）：Workspace 无
     workspace_id 属性，目标工作台 = 被更新记录本身（data.id / attributes.id）

  ## Ash 版本钉点

  Ash 3.31 的 filter 表达式是 struct（如 `%Ash.Query.Operator.Eq{left: %Ash.Query.Ref{}}`），
  不是 tuple AST，提取时需按 struct 匹配 —— 见 membership_context_test.exs 的
  resolve_workspace_id 钉测（用真实 Ash.Query 生成的 filter 断言，Ash 升级改 struct
  形状时测试当场失败，指明唯一需要改动的模块）。
  """
  @spec resolve_workspace_id(map) :: String.t() | nil
  def resolve_workspace_id(%{changeset: %Ash.Changeset{} = changeset}) do
    changeset.tenant || changeset_workspace_id(changeset)
  end

  def resolve_workspace_id(%{query: %Ash.Query{} = query}) do
    query.tenant ||
      filter_workspace_id(query.filter) ||
      workspace_id_by_id_filter(query.filter, query.resource)
  end

  def resolve_workspace_id(_), do: nil

  # update/bulk 场景 changeset.data 可能为 nil，先保护再取
  # create 场景 workspace_id 可能尚未从 argument 写入 attribute（policy 在 change 前执行），
  # 回退检查 changeset.arguments
  defp changeset_workspace_id(changeset) do
    cond do
      changeset.data && Ash.Changeset.get_attribute(changeset, :workspace_id) ->
        Ash.Changeset.get_attribute(changeset, :workspace_id)

      Map.get(changeset.attributes, :workspace_id) ->
        Map.get(changeset.attributes, :workspace_id)

      Ash.Changeset.get_argument(changeset, :workspace_id) ->
        Ash.Changeset.get_argument(changeset, :workspace_id)

      true ->
        workspace_self_id(changeset)
    end
  end

  # #78：目标资源即 Workspace 时，工作台 id = 被更新记录自身 id（data 可能为 nil，
  # 回退 attributes）。仅限 Workspace 资源 —— 其它租户资源的 data.id 是记录自身
  # 主键（如 membership id），不能误当作 workspace_id。
  defp workspace_self_id(%Ash.Changeset{resource: Cgc2046.Accounts.Workspace} = changeset) do
    if changeset.data do
      Ash.Changeset.get_attribute(changeset, :id)
    else
      Map.get(changeset.attributes, :id)
    end
  end

  defp workspace_self_id(_changeset), do: nil

  # actor 成员资格查询形状的唯一实现（membership_of / memberships_of_actor 共用）
  defp actor_memberships_query(actor) do
    WorkspaceMembership
    |> Ash.Query.filter(user_id == ^actor.id)
    |> Ash.Query.load(:roles)
  end

  # -- filter 提取 -----------------------------------------------------------

  # 成员列表 filter（如 GraphQL workspaceId: { eq: "..." }）生成
  # `%Ash.Query.Operator.Eq{left: %Ash.Query.Ref{name: :workspace_id}, right: value}`
  defp filter_workspace_id(%Ash.Filter{expression: expression}) do
    workspace_id_from_expr(expression)
  end

  defp filter_workspace_id(_), do: nil

  defp workspace_id_from_expr(%Ash.Query.Operator.Eq{left: left, right: right}) do
    cond do
      workspace_id_ref?(left) -> value_of(right)
      workspace_id_ref?(right) -> value_of(left)
      true -> nil
    end
  end

  defp workspace_id_from_expr(%Ash.Query.BooleanExpression{
         op: op,
         left: left,
         right: right
       })
       when op in [:and, :or] do
    workspace_id_from_expr(left) || workspace_id_from_expr(right)
  end

  defp workspace_id_from_expr(_), do: nil

  defp workspace_id_ref?(%Ash.Query.Ref{attribute: %{name: :workspace_id}}), do: true
  defp workspace_id_ref?(_), do: false

  defp value_of(value) when is_binary(value), do: value
  defp value_of(_), do: nil

  # get-by-id 场景：filter 形如 `id == "xxx"`（GraphQL update mutation 先按 id 读目标记录），
  # 无 workspace_id 条件，按 id 读出记录后取其 workspace_id。
  #
  # 使用 query.resource 动态决定读取的资源类型（而非硬编码 WorkspaceMembership），
  # 因为 policy 检查可能发生在 JoinRequest、Invitation 等非 Membership 资源上
  # （如 approveJoinRequest 的 WorkspaceActorIsOwnerOrAdmin 检查）。
  #
  # Workspace 特判（#88）：Workspace 无 :workspace_id attribute（点访问会抛 KeyError），
  # 且它就是目标工作台本身 → 返回 record.id（与 #78 workspace_self_id 同语义）。
  defp workspace_id_by_id_filter(
         %Ash.Filter{
           expression: %Ash.Query.Operator.Eq{
             left: %Ash.Query.Ref{attribute: %{name: :id}},
             right: id
           }
         },
         resource
       )
       when is_binary(id) do
    case Ash.get(resource, id, authorize?: false) do
      # Workspace 是全局资源，无 :workspace_id attribute，其 id 即 workspace_id
      # （#88，与 #78 workspace_self_id 的 changeset 语义一致）；其它租户资源
      # （WorkspaceMembership / JoinRequest / Invitation）取 record.workspace_id。
      # 新增其它无 :workspace_id 的全局资源时需在此同步处理。
      {:ok, record} ->
        if resource == Cgc2046.Accounts.Workspace, do: record.id, else: record.workspace_id

      _ ->
        nil
    end
  end

  defp workspace_id_by_id_filter(_, _resource), do: nil

  # ── 成员入座（写入面）─────────────────────────────────────────────

  @doc """
  把新注册用户入座到默认社区 workspace `2046`（ADR-0004 §3.5）。

  注册流程在 GraphQL signUp 创建 User 后调用：查默认 workspace(幂等)→
  admit_member(member 角色, 幂等)→ 建该 user 在 2046 的 WorkspaceProfile
  （复制全局 profile 字段, 默认 visibility=only_me）。保证"注册即有 workspace
  上下文"可编辑 per-workspace 档案。

  ## 降级语义

  默认 workspace 加入失败**不阻断注册**（2046 是保障而非硬依赖）——调用方
  （graphql signUp）应捕获返回并仅记录日志。返回：
  - `{:ok, membership}` 入座成功（或幂等已入座）
  - `{:error, :workspace_not_found}` 默认 workspace 未 seed（迁移未跑/被删）
  - `{:error, _}` 其它失败（admit_member / profile 创建）
  """
  @spec admit_to_default_workspace(String.t()) :: {:ok, term} | {:error, term}
  def admit_to_default_workspace(user_id) do
    with {:ok, workspace} <- find_default_workspace(),
         {:ok, membership} <-
           admit_member(user_id, workspace.id, [:member], on_conflict: :idempotent) do
      # 建 WorkspaceProfile（create action 默认 visibility=only_me / theme=dark / skills=[]；
      # 冲突 = 已有档案，跳过）。失败不阻断入座（档案可后续 lazy 建）。
      WorkspaceProfile
      |> Ash.Changeset.for_create(:create, %{user_id: user_id})
      |> Ash.create(tenant: workspace.id, authorize?: false)

      {:ok, membership}
    end
  end

  # 查默认 workspace（by slug，幂等；Workspace 为全局资源无 tenant）
  defp find_default_workspace do
    case Cgc2046.Accounts.Workspace
         |> Ash.Query.for_read(:get_by_slug, %{slug: @default_workspace_slug})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :workspace_not_found}
      {:ok, workspace} -> {:ok, workspace}
      {:error, _error} -> {:error, :workspace_not_found}
    end
  end

  # 业务错误文案作为 opt 传入：Invitation 对受邀人说「你」、JoinRequest 对审批方说「该用户」，
  # 两个 action 的调用方视角不同（自助 vs 管理员代操作），文案差异是 UX 契约，抽出后保留。
  @enroll_already_member_default "该用户已是本工作台成员"

  @doc """
  把一个用户入座到工作台：建 Membership + 按角色名入座 MembershipRole + 并发 unique 处理。

  这是「加入工作台」不变量的唯一实现（Invitation.accept / JoinRequest.approve /
  Workspace.join 三处 after_action 的入座段委托此处）。承担：

  1. existing 守卫：已是成员 → `{:error, business_error}`（不重复建 Membership）
  2. 建 Membership（并发下两个调用可能同时越过守卫，DB unique index 兜底）
  3. 按角色名查 role record 入座 MembershipRole（reduce_while 短路，失败返回结构化错误）
  4. unique 冲突按 `on_conflict` 转换：`:business_error` 转「已是成员」/ `:idempotent` 返成功
  5. 非 unique 的真实 DB 故障原样上抛，不吞成「已是成员」（防静默数据丢失）

  ## 事务边界

  事务无关纯函数——不自己开事务，继承调用方 action 的事务上下文。Invitation.accept /
  JoinRequest.approve 的 after_action 在父事务内，入座失败 rollback 父 action（状态 claim
  一并回滚）；Workspace.join 的 `transaction?: false` 下两次写各自 autocommit，
  MembershipRole 失败留孤儿 membership（已知风险，见 workspace.ex ponytail 注释，
  升级路径为给 :join 加 transaction?: true，不在本函数职责内）。

  ## opts

  - `:on_conflict` — `:business_error`（默认，Invitation/JoinRequest）| `:idempotent`（Workspace.join）
  - `:error_message` — 「已是成员」业务错误文案（默认「该用户已是本工作台成员」）

  ## 返回

  - `{:ok, membership}` — 入座成功（或幂等成功时为已有的 membership）
  - `{:error, error}` — existing 守卫 / unique→业务错误 / 真 DB 故障 / MembershipRole 创建失败
  """
  @spec admit_member(String.t(), String.t(), [atom], keyword) ::
          {:ok, WorkspaceMembership.t()} | {:error, term}
  def admit_member(user_id, workspace_id, role_names, opts \\ []) do
    on_conflict = Keyword.get(opts, :on_conflict, :business_error)
    error_message = Keyword.get(opts, :error_message, @enroll_already_member_default)
    role_names = List.wrap(role_names)

    # existing 守卫：已是成员时按 on_conflict 分流——
    # - :idempotent（Workspace.join）→ 幂等成功，回查已有 membership 返回（不报错）
    # - :business_error（Invitation/JoinRequest）→ 转「已是成员」业务错误
    # 非 bang Ash.read + case：读失败返结构化错误而非 raise——「已是成员」是业务判定
    # 必须准确（不能吞成 nil 继续建），但也不该 raise 把结构化错误变成 500（#14 原则；
    # Workspace.join 是 generic action transaction?: false，raise 在此最危险）。
    # fail-closed 不变量保持：读失败既不建 membership 也不假装成功，上抛结构化错误。
    existing_result =
      WorkspaceMembership
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(workspace_id == ^workspace_id and user_id == ^user_id)
      |> Ash.read(tenant: workspace_id, authorize?: false)

    case existing_result do
      {:ok, []} ->
        create_membership_and_roles(user_id, workspace_id, role_names, on_conflict, error_message)

      {:ok, [membership | _]} when on_conflict == :idempotent ->
        {:ok, membership}

      {:ok, [_ | _]} ->
        {:error, already_member_error(error_message)}

      {:error, _error} ->
        {:error, membership_check_error()}
    end
  end

  defp create_membership_and_roles(user_id, workspace_id, role_names, on_conflict, error_message) do
    # Ash.create 省略 actor：authorize?: false 下 actor 不参与 policy 判定，
    # 且 WorkspaceMembership / MembershipRole 的 create action 无读 actor 的 change（无审计字段），
    # 故 actor 在此无作用。事务边界由调用方 action 控制（见 admit_member doc 事务边界段）。
    case WorkspaceMembership
         |> Ash.Changeset.for_create(:create, %{user_id: user_id})
         |> Ash.create(tenant: workspace_id, authorize?: false) do
      {:ok, membership} ->
        # 空 role_names → 建 Membership 不建 MembershipRole（决策 6：无预授权角色待 Owner 手动 assign）
        if role_names != [] do
          # 非 bang Ash.read：读角色表失败返结构化错误而非 raise（与 existing 守卫 / 幂等回查统一，
          # #14 原则）。:join 是 transaction?: false，Membership 已 commit 后读角色 raise 会留孤儿 membership。
          with {:ok, roles} <-
                 Ash.read(Cgc2046.Accounts.Role, tenant: workspace_id, authorize?: false) do
            seat_roles(membership, role_names, roles, workspace_id)
          else
            {:error, _error} -> {:error, membership_check_error()}
          end
        else
          {:ok, membership}
        end

      {:error, error} ->
        if unique_membership_conflict?(error) do
          handle_unique_conflict(on_conflict, error_message, workspace_id, user_id)
        else
          # 非 unique 的真实 DB 故障（连接断、磁盘满）必须原样上抛，不能吞成「已是成员」，
          # 否则用户被误导且无告警（静默数据丢失）。
          {:error, error}
        end
    end
  end

  # 按角色名入座 MembershipRole：reduce_while 短路，任一创建失败返回 {:error, _}。
  # 角色名在租户内找不到对应 role record → 跳过该角色（与三处原 reduce_while 行为一致，
  # 容错预授权/审批传入了租户内不存在的角色名）。
  defp seat_roles(membership, role_names, roles, workspace_id) do
    Enum.reduce_while(role_names, {:ok, membership}, fn role_name, _acc ->
      role = Enum.find(roles, &(&1.name == role_name))

      if role do
        # actor 省略理由同 create_membership_and_roles（authorize?: false，create action 无 actor 依赖）
        case Ash.create(
               Cgc2046.Accounts.MembershipRole,
               %{membership_id: membership.id, role_id: role.id},
               tenant: workspace_id,
               authorize?: false
             ) do
          {:ok, _} -> {:cont, {:ok, membership}}
          {:error, error} -> {:halt, {:error, error}}
        end
      else
        {:cont, {:ok, membership}}
      end
    end)
  end

  # unique 冲突的两种外露姿态（同一不变量）：
  # - :business_error → 转「已是成员」业务错误（Invitation.accept / JoinRequest.approve）
  # - :idempotent → 幂等成功，回查已有 membership 返回（Workspace.join）
  defp handle_unique_conflict(:idempotent, _error_message, workspace_id, user_id) do
    # 幂等成功：并发下另一请求已建 Membership，回查取已有记录返回。
    # 非 bang Ash.read：回查失败（连接断、极端：刚建好又被删）按保守方向当结构化错误，
    # 不 raise 也不假装成功（#14 原则）。
    WorkspaceMembership
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(workspace_id == ^workspace_id and user_id == ^user_id)
    |> Ash.read(tenant: workspace_id, authorize?: false)
    |> case do
      {:ok, [membership | _]} -> {:ok, membership}
      {:ok, []} -> {:error, already_member_error(@enroll_already_member_default)}
      {:error, _error} -> {:error, membership_check_error()}
    end
  end

  defp handle_unique_conflict(:business_error, error_message, _workspace_id, _user_id) do
    {:error, already_member_error(error_message)}
  end

  defp already_member_error(message) do
    Ash.Error.Changes.InvalidAttribute.exception(field: :user_id, message: message)
  end

  # existing 守卫 / 幂等回查的 DB 读失败：fail-closed 结构化错误。
  # 既不吞成 nil 继续建 membership（静默数据丢失），也不 raise 把错误变成 500
  # （#14 原则：结构化错误走 ash_graphql to_errors）。
  defp membership_check_error do
    Ash.Error.Changes.InvalidAttribute.exception(
      field: :user_id,
      message: "成员资格检查失败"
    )
  end

  @doc """
  判断 Ash.create/ash_postgres 返回的 error 是否为 membership unique constraint 冲突。

  ash_postgres 把 `wm_unique_ws_user_idx`（identity :unique_membership_per_workspace_user）
  的 PG unique violation 转成 `Ash.Error.Invalid{errors: [InvalidAttribute{private_vars: [constraint_type: :unique]}]}`。
  DB 断连、磁盘满等真实写失败不会带 `constraint_type: :unique`——调用方据此区分
  「并发重复，可幂等/转业务错误」与「真实故障，必须上抛」。避免 `{:error, _}` 通配
  把 DB 故障误判成「已是成员/成功」的静默数据丢失。
  """
  @spec unique_membership_conflict?(term) :: boolean
  def unique_membership_conflict?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &unique_constraint_leaf?/1)
  end

  # Ash.create 通常返回 Splode error class（%Ash.Error.Invalid{errors: [...]}），
  # 但某些路径可能直接返回裸 leaf，兼容判断。
  def unique_membership_conflict?(%Ash.Error.Changes.InvalidAttribute{} = leaf) do
    unique_constraint_leaf?(leaf)
  end

  def unique_membership_conflict?(_), do: false

  defp unique_constraint_leaf?(%Ash.Error.Changes.InvalidAttribute{
         private_vars: private_vars
       }) do
    # private_vars 可能为 nil（InvalidAttribute 未传该字段时）
    Keyword.get(private_vars || [], :constraint_type) == :unique
  end

  defp unique_constraint_leaf?(_), do: false
end
