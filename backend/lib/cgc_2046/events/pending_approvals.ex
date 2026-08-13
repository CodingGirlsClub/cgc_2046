defmodule Cgc2046.Events.PendingApprovals do
  @moduledoc """
  当前 actor 的跨工作台审批待办聚合。

  工作台集合先由成员资格与 RBAC 收窄为 owner/admin；随后每个工作台分别通过
  Enrollment/JoinRequest 的真实 read action 与 policy 查询 pending 记录。这样普通
  成员和非成员在查询层即得到空集，不在 resolver 读取全量后做响应过滤。

  行形状（E-8 #123 决策 D7）：`{kind, id, requester 摘要, context 摘要,
  approval_deadline}`。requester/context 摘要（display_name、Event/Course 标题、
  Workspace 名称）在聚合后批量装配（内部读，`authorize?: false`——行可见性已由
  上方 owner/admin 收窄 + policy 查询保证，摘要只是同权限范围内的展示字段）。

  `include_expired: true` 时附带 expired 行（审批页「已过期」区，只读展示，
  不可通过/拒绝——重提是申请者侧动作，过期后唯一索引已放行重新报名/申请）。
  """

  require Ash.Query

  alias Cgc2046.Accounts.{JoinRequest, MembershipContext, Role, User, Workspace}
  alias Cgc2046.Events.{Course, Enrollment, Event, Sponsorship}

  @spec list(term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(actor, opts \\ []) do
    include_expired = Keyword.get(opts, :include_expired, false)
    workspace_ids = managed_workspace_ids(actor)

    with {:ok, pending} <- collect_pending(workspace_ids, actor),
         {:ok, expired} <- collect_expired(workspace_ids, actor, include_expired) do
      rows =
        (Enum.sort_by(pending, &sort_key/1) ++
           Enum.sort_by(expired, &expired_key/1, {:desc, DateTime}))
        |> enrich()

      {:ok, rows}
    end
  end

  defp managed_workspace_ids(actor) do
    actor
    |> MembershipContext.memberships_of_actor()
    |> Enum.filter(fn membership ->
      membership.roles
      |> Enum.map(& &1.name)
      |> Enum.any?(&Role.manage_role?/1)
    end)
    |> Enum.map(& &1.workspace_id)
    |> Enum.uniq()
  end

  defp collect_pending(workspace_ids, actor) do
    Enum.reduce_while(workspace_ids, {:ok, []}, fn workspace_id, {:ok, acc} ->
      with {:ok, enrollments} <- pending_enrollments(workspace_id, actor),
           {:ok, join_requests} <- pending_join_requests(workspace_id, actor),
           {:ok, sponsorships} <- pending_sponsorships(workspace_id, actor) do
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

  defp collect_expired(_workspace_ids, _actor, false), do: {:ok, []}

  defp collect_expired(workspace_ids, actor, true) do
    Enum.reduce_while(workspace_ids, {:ok, []}, fn workspace_id, {:ok, acc} ->
      with {:ok, enrollments} <- expired_enrollments(workspace_id, actor),
           {:ok, join_requests} <- expired_join_requests(workspace_id, actor),
           {:ok, sponsorships} <- expired_sponsorships(workspace_id, actor) do
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

  defp pending_sponsorships(workspace_id, actor) do
    Sponsorship
    |> Ash.Query.filter(status == :pending)
    |> Ash.read(tenant: workspace_id, actor: actor)
  end

  defp expired_sponsorships(workspace_id, actor) do
    Sponsorship
    |> Ash.Query.filter(status == :expired)
    |> Ash.read(tenant: workspace_id, actor: actor)
  end

  defp from_enrollment(enrollment, _status) do
    %{
      id: enrollment.id,
      kind: "enrollment",
      workspace_id: enrollment.workspace_id,
      user_id: enrollment.user_id,
      event_id: enrollment.event_id,
      course_id: enrollment.course_id,
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
      user_id: join_request.user_id,
      event_id: nil,
      course_id: nil,
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
      user_id: sponsorship.sponsor_user_id,
      event_id: sponsorship.event_id,
      course_id: nil,
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
    workspace_names = load_workspace_names(rows)
    titles = load_offering_titles(rows)

    Enum.map(rows, fn row ->
      workspace_name = Map.get(workspace_names, row.workspace_id)

      %{
        row
        | requester_name: requester_name(row, user_names),
          workspace_name: workspace_name,
          context_title: context_title(row, titles, workspace_name)
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

  defp load_workspace_names(rows) do
    ids = rows |> Enum.map(& &1.workspace_id) |> Enum.uniq()

    Workspace
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn workspace -> {workspace.id, workspace.name} end)
  end

  defp load_offering_titles(rows) do
    by_workspace = Enum.group_by(rows, & &1.workspace_id)

    Enum.reduce(by_workspace, %{}, fn {workspace_id, ws_rows}, acc ->
      event_ids = ws_rows |> Enum.map(& &1.event_id) |> Enum.reject(&is_nil/1)
      course_ids = ws_rows |> Enum.map(& &1.course_id) |> Enum.reject(&is_nil/1)

      acc
      |> Map.merge(titles_for(Event, event_ids, workspace_id))
      |> Map.merge(titles_for(Course, course_ids, workspace_id))
    end)
  end

  defp titles_for(_resource, [], _workspace_id), do: %{}

  defp titles_for(resource, ids, workspace_id) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(tenant: workspace_id, authorize?: false)
    |> Map.new(fn offering -> {offering.id, offering.title} end)
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
