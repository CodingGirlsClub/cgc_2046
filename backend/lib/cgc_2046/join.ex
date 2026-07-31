defmodule Cgc2046.Join do
  @moduledoc """
  加入流程服务(T06,spec §12):三态加入策略的实现载体。

  - `join_open/2` — open 空间:直接加入并自动获得 Learner 角色(幂等:
    已加入则返回现有 membership)
  - `submit_request/3` — request 空间:创建 JoinRequest(pending),
    由 Owner/Admin 审批(JoinRequest.approve/reject)
  - invite_only 空间**不**走 join 端点(仅邀请链接可加入,见
    `Cgc2046.Workspaces.Invitation` 的 `consume` 通用 action)

  授权:open/request 空间对任何已认证用户开放(join_policy 即规则本身);
  服务内显式校验 join_policy,防止被误用;member/角色创建走
  `authorize?: false`(标准 member:manage 策略不适用于自助加入流程)。
  """

  alias Cgc2046.Workspaces.{MembershipRole, Role, WorkspaceMembership, Workspace, JoinRequest}

  import Ash.Query, only: [filter: 2]

  @doc """
  open 策略:直接加入并自动获得 Learner 角色。

  返回 `{:ok, membership}`(幂等:已是成员则返回现有 membership)。
  workspace 非 open 策略 → `{:error, :not_open}`。
  """
  def join_open(%Workspace{join_policy: :open} = workspace, actor) do
    tenant = workspace.id

    membership =
      case WorkspaceMembership
           |> filter(user_id == ^actor.id)
           |> Ash.read_one(tenant: tenant, authorize?: false) do
        {:ok, nil} ->
          {:ok, m} =
            Ash.create(WorkspaceMembership, %{user_id: actor.id},
              tenant: tenant,
              authorize?: false
            )

          m

        {:ok, m} ->
          m
      end

    learner = learner_role!(tenant)

    exists? =
      case MembershipRole
           |> filter(membership_id == ^membership.id)
           |> filter(role_id == ^learner.id)
           |> Ash.read_one(tenant: tenant, authorize?: false) do
        {:ok, nil} -> false
        _ -> true
      end

    unless exists? do
      Ash.create!(MembershipRole, %{membership_id: membership.id, role_id: learner.id},
        tenant: tenant,
        authorize?: false
      )
    end

    {:ok, membership}
  end

  def join_open(%Workspace{}, _actor), do: {:error, :not_open}

  @doc """
  request 策略:创建 JoinRequest(pending),待 Owner/Admin 审批。

  可附带 `requested_role_ids`(申请人意向角色,审批方决定最终角色)。
  非 request 策略 workspace → `{:error, :not_request}`。
  """
  def submit_request(workspace, actor, requested_role_ids \\ [])

  def submit_request(%Workspace{join_policy: :request} = workspace, actor, requested_role_ids) do
    case Ash.create(JoinRequest, %{requested_role_ids: requested_role_ids},
           actor: actor,
           tenant: workspace.id
         ) do
      {:ok, join_request} -> {:ok, join_request}
      {:error, error} -> {:error, error}
    end
  end

  def submit_request(%Workspace{}, _actor, _requested_role_ids), do: {:error, :not_request}

  defp learner_role!(tenant) do
    Role
    |> filter(name == "Learner")
    |> Ash.read_one!(tenant: tenant, authorize?: false)
  end
end
