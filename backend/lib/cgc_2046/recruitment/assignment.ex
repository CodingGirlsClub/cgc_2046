defmodule Cgc2046.Recruitment.Assignment do
  @moduledoc """
  R15 项目分配的跨域副作用（U3 的 assign action 只落域内事实，本模块补齐编排）。

  在 assign 流转的**同一事务内**（fail-closed）依次完成：

  1. 邀请申请人加入目标 workspace（`MembershipContext.admit_member/4`，
     `:idempotent`——重复分配不炸）；
  2. 按职位映射既有 workspace 角色（KTD4：场次主理人/活动教练 → `volunteer`；
     教程研究员 → `tutor`；**不新增 RBAC 角色**）；
  3. 主理人（`assigned_event_id` 非空）→ `EventModerator` 指派
     （`Moderators.ensure_assigned/2`，成员前提由上一步保证；教程研究员无场次
     指派，课程任务只落申请行的 `assignment_note`）。

  失败整体回滚（申请保持 `training`，运营可重试）——绝不落「状态已分配但没入台 /
  没指派」的半成品（AE4）。离场撤权见 R15 尾句（面板操作，不在此模块）。
  """

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Events.{Event, Moderators}

  # 职位 → 角色映射单源（KTD4）。职位枚举与 RBAC 角色的 `tutor` 同名是刻意对齐，
  # 不是同一个概念：前者是招募域职位，后者是权限域角色。
  @position_roles %{
    event_moderator: [:volunteer],
    coach: [:volunteer],
    tutor: [:tutor]
  }

  @doc """
  完成分配副作用。`attrs` 取 `%{user_id, workspace_id, position, assigned_event_id}`。

  返回 `:ok`，或 `{:error, reason}`——调用方（assign action）负责转稳定业务错误
  并回滚事务。
  """
  @spec complete(map()) :: :ok | {:error, term()}
  def complete(attrs) do
    with {:ok, _membership} <- admit(attrs),
         :ok <- ensure_moderator(attrs) do
      :ok
    end
  end

  @doc "职位 → 角色映射（单源导出，供测试与文档引用）"
  def roles_for(position), do: Map.get(@position_roles, position, [])

  defp admit(%{user_id: user_id, workspace_id: workspace_id, position: position}) do
    MembershipContext.admit_member(
      user_id,
      workspace_id,
      roles_for(position),
      on_conflict: :idempotent
    )
  end

  defp ensure_moderator(%{assigned_event_id: nil}), do: :ok

  defp ensure_moderator(%{
         workspace_id: workspace_id,
         user_id: user_id,
         assigned_event_id: event_id
       }) do
    case Ash.get(Event, event_id, tenant: workspace_id, authorize?: false) do
      {:ok, nil} -> {:error, :assigned_event_not_found}
      {:ok, event} -> Moderators.ensure_assigned(event, user_id)
      {:error, error} -> {:error, error}
    end
  end
end
