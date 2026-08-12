defmodule Cgc2046.Events.PendingApprovals do
  @moduledoc """
  当前 actor 的跨工作台审批待办聚合。

  工作台集合先由成员资格与 RBAC 收窄为 owner/admin；随后每个工作台分别通过
  Enrollment/JoinRequest 的真实 read action 与 policy 查询 pending 记录。这样普通
  成员和非成员在查询层即得到空集，不在 resolver 读取全量后做响应过滤。
  """

  require Ash.Query

  alias Cgc2046.Accounts.{JoinRequest, MembershipContext, Role}
  alias Cgc2046.Events.Enrollment

  @spec list(term()) :: {:ok, [map()]} | {:error, term()}
  def list(actor) do
    actor
    |> managed_workspace_ids()
    |> Enum.reduce_while({:ok, []}, fn workspace_id, {:ok, acc} ->
      with {:ok, enrollments} <- pending_enrollments(workspace_id, actor),
           {:ok, join_requests} <- pending_join_requests(workspace_id, actor) do
        items =
          Enum.map(enrollments, &from_enrollment/1) ++
            Enum.map(join_requests, &from_join_request/1)

        {:cont, {:ok, items ++ acc}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.sort_by(items, &sort_key/1)}
      error -> error
    end)
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

  defp from_enrollment(enrollment) do
    %{
      id: enrollment.id,
      kind: "enrollment",
      workspace_id: enrollment.workspace_id,
      user_id: enrollment.user_id,
      event_id: enrollment.event_id,
      course_id: enrollment.course_id,
      status: to_string(enrollment.status),
      approval_deadline: enrollment.approval_deadline
    }
  end

  defp from_join_request(join_request) do
    %{
      id: join_request.id,
      kind: "join_request",
      workspace_id: join_request.workspace_id,
      user_id: join_request.user_id,
      event_id: nil,
      course_id: nil,
      status: to_string(join_request.status),
      approval_deadline: join_request.approval_deadline
    }
  end

  defp sort_key(%{approval_deadline: nil, id: id}), do: {1, nil, id}
  defp sort_key(%{approval_deadline: deadline, id: id}), do: {0, deadline, id}
end
