defmodule Cgc2046.PendingApprovals do
  @moduledoc """
  当前 actor 的跨工作台审批待办聚合。

  工作台集合先由成员资格与 RBAC 收窄为 owner/admin；随后每个工作台分别通过
  Enrollment/JoinRequest 的真实 read action 与 policy 查询 pending 记录。这样普通
  成员和非成员在查询层即得到空集，不在 resolver 读取全量后做响应过滤。

  赞助（Sponsorship）读面再按 level 行级细分：每个工作台的角色集经
  `SponsorshipApprover.approver_roles/1` 反查可审批的 level 集（`level in
  ^allowed_levels` 下推到 pending / expired / count 三路径）——admin 无
  workspace 级行（拍板 #4，与写面 policy 一致：admin 看到即点不动的行不出现在
  待办读面）。

  行形状（E-8 #123 决策 D7）：`{kind, id, requester 摘要, context 摘要,
  approval_deadline}`。requester/context 摘要（display_name、Event/Course 标题、
  Workspace 名称）在聚合后批量装配（内部读，`authorize?: false`——行可见性已由
  上方 owner/admin 收窄 + policy 查询保证，摘要只是同权限范围内的展示字段）。
  另携带 `workspace_slug`（全 kind）与 `event_slug`（sponsorship event 级）——
  E-9 #123 expired 重提链接的落点字段（`/join?workspace=`、`/events/<slug>`、
  `/w/<slug>`；Event slug 可空，前端按缺失降级）。

  `include_expired: true` 时附带 expired 行（审批页「已过期」区，只读展示，
  不可通过/拒绝——重提是申请者侧动作，过期后唯一索引已放行重新报名/申请）。

  `count_pending/1` 是角标轻量路径：复用同一 owner/admin 工作台收窄，对三类资源
  `Ash.count`，不物化行、不走 `list/2` / enrich。口径是可操作 pending（KTD8：
  `approval_deadline <= now` 不计，nil 视为未过期），与 `/approvals` 展示含过期
  行有意不同——见 `graphql_pending_approvals_count_test.exs` 与
  `graphql_pending_approvals_test.exs` 互引。
  """

  require Ash.Query

  alias Cgc2046.Accounts.{JoinRequest, MembershipContext, Role, User, Workspace}
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Sponsorship.Sponsorship
  alias Cgc2046.Sponsorship.Policies.SponsorshipApprover

  @spec list(term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(actor, opts \\ []) do
    include_expired = Keyword.get(opts, :include_expired, false)
    managed_workspaces = managed_workspace_ids(actor)

    with {:ok, pending} <- collect_pending(managed_workspaces, actor),
         {:ok, expired} <- collect_expired(managed_workspaces, actor, include_expired) do
      rows =
        (Enum.sort_by(pending, &sort_key/1) ++
           Enum.sort_by(expired, &expired_key/1, {:desc, DateTime}))
        |> enrich()

      {:ok, rows}
    end
  end

  @spec count_pending(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  # KTD8：角标只计可操作 pending。`/approvals` 的 myPendingApprovals(includeExpired)
  # 仍展示过期行（见 graphql_pending_approvals_test.exs）；两边不要顺手统一。
  def count_pending(actor) do
    now = DateTime.utc_now()

    Enum.reduce_while(managed_workspace_ids(actor), {:ok, 0}, fn {workspace_id, allowed_levels},
                                                                 {:ok, total} ->
      with {:ok, enrollment_count} <-
             count_pending(Enrollment, workspace_id, actor, now, allowed_levels),
           {:ok, join_request_count} <-
             count_pending(JoinRequest, workspace_id, actor, now, allowed_levels),
           {:ok, sponsorship_count} <-
             count_pending(Sponsorship, workspace_id, actor, now, allowed_levels) do
        {:cont, {:ok, total + enrollment_count + join_request_count + sponsorship_count}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp count_pending(resource, workspace_id, actor, now, _allowed_levels)
       when resource in [Enrollment, JoinRequest] do
    resource
    |> Ash.Query.filter(
      status == :pending and (is_nil(approval_deadline) or approval_deadline > ^now)
    )
    |> Ash.count(tenant: workspace_id, actor: actor)
  end

  # Sponsorship 按 level 行级过滤（拍板 #4：角色集经 approver_roles/1 反查
  # allowed_levels；count 保持 SQL 聚合不物化行）。
  defp count_pending(Sponsorship, workspace_id, actor, now, allowed_levels) do
    Sponsorship
    |> Ash.Query.filter(
      status == :pending and (is_nil(approval_deadline) or approval_deadline > ^now) and
        level in ^allowed_levels
    )
    |> Ash.count(tenant: workspace_id, actor: actor)
  end

  # 管理角色成员的工作台 → `{workspace_id, allowed_levels}`（allowed_levels =
  # 该角色集能审批的赞助级别集，经 `SponsorshipApprover.approver_roles/1` 反查）。
  # `memberships_of_actor/1` 已 load roles，无 N+1；同一 workspace 多条 membership
  # 罕见，以任一管理 membership 的角色集为准（与原 uniq 保序首个行为一致）。
  defp managed_workspace_ids(actor) do
    actor
    |> MembershipContext.memberships_of_actor()
    |> Enum.filter(fn membership ->
      membership.roles
      |> Enum.map(& &1.name)
      |> Enum.any?(&Role.manage_role?/1)
    end)
    |> Enum.map(fn membership ->
      roles = Enum.map(membership.roles, & &1.name)
      {membership.workspace_id, allowed_levels(roles)}
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp allowed_levels(roles) do
    [:event, :workspace]
    |> Enum.filter(fn level ->
      Enum.any?(roles, &(&1 in SponsorshipApprover.approver_roles(level)))
    end)
  end

  defp collect_pending(managed_workspaces, actor) do
    Enum.reduce_while(managed_workspaces, {:ok, []}, fn {workspace_id, allowed_levels},
                                                        {:ok, acc} ->
      with {:ok, enrollments} <- pending_enrollments(workspace_id, actor),
           {:ok, join_requests} <- pending_join_requests(workspace_id, actor),
           {:ok, sponsorships} <- pending_sponsorships(workspace_id, actor, allowed_levels) do
        items =
          Enum.map(enrollments, &from_enrollment(&1, :pending)) ++
            Enum.map(join_requests, &from_join_request(&1, :pending)) ++
            Enum.map(sponsorships, &from_sponsorship(&1, :pending))

        {:cont, {:ok, items ++ acc}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_expired(_managed_workspaces, _actor, false), do: {:ok, []}

  defp collect_expired(managed_workspaces, actor, true) do
    Enum.reduce_while(managed_workspaces, {:ok, []}, fn {workspace_id, allowed_levels},
                                                        {:ok, acc} ->
      with {:ok, enrollments} <- expired_enrollments(workspace_id, actor),
           {:ok, join_requests} <- expired_join_requests(workspace_id, actor),
           {:ok, sponsorships} <- expired_sponsorships(workspace_id, actor, allowed_levels) do
        items =
          Enum.map(enrollments, &from_enrollment(&1, :expired)) ++
            Enum.map(join_requests, &from_join_request(&1, :expired)) ++
            Enum.map(sponsorships, &from_sponsorship(&1, :expired))

        {:cont, {:ok, items ++ acc}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp pending_enrollments(workspace_id, actor) do
    Enrollment
    |> Ash.Query.filter(status == :pending)
    |> Ash.read(tenant: workspace_id, actor: actor)
  end

  defp pending_join_requests(workspace_id, actor) do
    JoinRequest
    |> Ash.Query.filter(status == :pending)
    |> Ash.read(tenant: workspace_id, actor: actor)
  end

  defp expired_enrollments(workspace_id, actor) do
    Enrollment
    |> Ash.Query.filter(status == :expired)
    |> Ash.read(tenant: workspace_id, actor: actor)
  end

  defp expired_join_requests(workspace_id, actor) do
    JoinRequest
    |> Ash.Query.filter(status == :expired)
    |> Ash.read(tenant: workspace_id, actor: actor)
  end

  # Sponsorship 行级过滤（拍板 #4）：allowed_levels 由该工作台角色集经
  # approver_roles/1 反查，admin 无 workspace 级行（与写面 policy 一致）。
  defp pending_sponsorships(workspace_id, actor, allowed_levels) do
    Sponsorship
    |> Ash.Query.filter(status == :pending and level in ^allowed_levels)
    |> Ash.read(tenant: workspace_id, actor: actor)
  end

  defp expired_sponsorships(workspace_id, actor, allowed_levels) do
    Sponsorship
    |> Ash.Query.filter(status == :expired and level in ^allowed_levels)
    |> Ash.read(tenant: workspace_id, actor: actor)
  end

  defp from_enrollment(enrollment, _status) do
    %{
      id: enrollment.id,
      kind: "enrollment",
      workspace_id: enrollment.workspace_id,
      workspace_slug: nil,
      user_id: enrollment.user_id,
      event_id: enrollment.event_id,
      course_id: enrollment.course_id,
      event_slug: nil,
      status: to_string(enrollment.status),
      approval_deadline: enrollment.approval_deadline,
      expired_at: enrollment.expired_at,
      requester_name: nil,
      workspace_name: nil,
      context_title: nil
    }
  end

  defp from_join_request(join_request, _status) do
    %{
      id: join_request.id,
      kind: "join_request",
      workspace_id: join_request.workspace_id,
      workspace_slug: nil,
      user_id: join_request.user_id,
      event_id: nil,
      course_id: nil,
      event_slug: nil,
      status: to_string(join_request.status),
      approval_deadline: join_request.approval_deadline,
      expired_at: join_request.expired_at,
      requester_name: nil,
      workspace_name: nil,
      context_title: nil
    }
  end

  # 赞助行：requester 摘要 = 公司名（sponsor 为全局账号，公司名即展示身份）；
  # context 摘要 = 目标 Event 名（Event 级）/ 目标 Workspace 名（Workspace 级）。
  defp from_sponsorship(sponsorship, _status) do
    %{
      id: sponsorship.id,
      kind: "sponsorship",
      workspace_id: sponsorship.workspace_id,
      workspace_slug: nil,
      user_id: sponsorship.sponsor_user_id,
      event_id: sponsorship.event_id,
      course_id: nil,
      event_slug: nil,
      level: to_string(sponsorship.level),
      status: to_string(sponsorship.status),
      approval_deadline: sponsorship.approval_deadline,
      expired_at: sponsorship.expired_at,
      company_name: sponsorship.company_name,
      contact_email: sponsorship.contact_email,
      tier_name: sponsorship.tier_name,
      amount: sponsorship.amount,
      requester_name: nil,
      workspace_name: nil,
      context_title: nil
    }
  end

  defp sort_key(%{approval_deadline: nil, id: id}), do: {1, nil, id}
  defp sort_key(%{approval_deadline: deadline, id: id}), do: {0, deadline, id}

  # expired 按过期时间倒序（最近过期在前）；nil 兜底排最前（不应出现，worker 必写 expired_at）。
  # 键必须是 DateTime——{:desc, DateTime} sorter 对键调 DateTime.compare，tuple 键会
  # FunctionClauseError（评审实证：两条以上 expired 行才触发）。
  defp expired_key(%{expired_at: nil}), do: ~U[9999-01-01 00:00:00Z]
  defp expired_key(%{expired_at: expired_at}), do: expired_at

  # ── 摘要装配（内部批量读；可见性已在聚合层收窄）──

  defp enrich(rows) do
    user_names = load_user_names(rows)
    workspace_infos = load_workspace_infos(rows)
    titles = load_offering_titles(rows)
    slugs = load_offering_slugs(rows)

    Enum.map(rows, fn row ->
      workspace_info = Map.get(workspace_infos, row.workspace_id)

      %{
        row
        | requester_name: requester_name(row, user_names),
          workspace_name: Map.get(workspace_info, :name),
          workspace_slug: Map.get(workspace_info, :slug),
          event_slug: Map.get(slugs, row.event_id),
          context_title: context_title(row, titles, Map.get(workspace_info, :name))
      }
    end)
  end

  # 赞助行的 requester 摘要用公司名（不查用户表；sponsor 账号名 ≠ 展示身份）。
  defp requester_name(%{kind: "sponsorship", company_name: company_name}, _user_names)
       when is_binary(company_name),
       do: company_name

  defp requester_name(row, user_names), do: Map.get(user_names, row.user_id)

  defp load_user_names(rows) do
    ids =
      rows
      |> Enum.reject(&(&1.kind == "sponsorship"))
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()

    User
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn user -> {user.id, user.display_name || to_string(user.email)} end)
  end

  defp load_workspace_infos(rows) do
    ids = rows |> Enum.map(& &1.workspace_id) |> Enum.uniq()

    Workspace
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn workspace ->
      {workspace.id, %{name: workspace.name, slug: workspace.slug}}
    end)
  end

  defp load_offering_titles(rows) do
    by_workspace = Enum.group_by(rows, & &1.workspace_id)

    Enum.reduce(by_workspace, %{}, fn {workspace_id, ws_rows}, acc ->
      ids_by_kind = %{
        event: ws_rows |> Enum.map(& &1.event_id) |> Enum.reject(&is_nil/1),
        course: ws_rows |> Enum.map(& &1.course_id) |> Enum.reject(&is_nil/1)
      }

      # 批量读取唯一真源 = Offering（per-kind per-tenant 批量，消 N+1 形状不变）
      Map.merge(acc, Cgc2046.Offering.fetch_titles_by_ids(ids_by_kind, workspace_id))
    end)
  end

  # expired 重提链接的 event slug 落点（enrollment 行也装载，前端仅 sponsorship 消费；
  # 无 slug 的供给物不出现在结果 → Map.get 得 nil，前端降级）。
  defp load_offering_slugs(rows) do
    by_workspace = Enum.group_by(rows, & &1.workspace_id)

    Enum.reduce(by_workspace, %{}, fn {workspace_id, ws_rows}, acc ->
      ids_by_kind = %{
        event: ws_rows |> Enum.map(& &1.event_id) |> Enum.reject(&is_nil/1),
        course: ws_rows |> Enum.map(& &1.course_id) |> Enum.reject(&is_nil/1)
      }

      Map.merge(acc, Cgc2046.Offering.fetch_slugs_by_ids(ids_by_kind, workspace_id))
    end)
  end

  defp context_title(%{kind: "join_request"}, _titles, workspace_name), do: workspace_name

  defp context_title(%{kind: "sponsorship", level: "workspace"}, _titles, workspace_name),
    do: workspace_name

  defp context_title(%{event_id: event_id}, titles, _workspace_name)
       when not is_nil(event_id),
       do: Map.get(titles, event_id)

  defp context_title(%{course_id: course_id}, titles, _workspace_name)
       when not is_nil(course_id),
       do: Map.get(titles, course_id)

  defp context_title(_row, _titles, _workspace_name), do: nil
end
