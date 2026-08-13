defmodule Cgc2046.Policies.SponsorshipApprover do
  @moduledoc """
  赞助审批权限（E-3 #48 拍板 #4）：

  - Event 级 = 目标工作台 Owner/Admin（多角色并集）；
  - Workspace 级 = **仅 Owner**（长期承诺加严；平台 Admin 备案二期，不参与审批）。

  level 取自被更新记录（changeset.data）；工作台 id 取自记录 workspace_id
  （Sponsorship 多租户属性）。非 Sponsorship 更新上下文一律拒绝。
  """

  use Ash.Policy.SimpleCheck

  alias Cgc2046.Accounts.{MembershipContext, Role}

  @impl true
  def describe(_opts), do: "actor is the designated approver for this sponsorship level"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(
        actor,
        %{changeset: %Ash.Changeset{data: %{level: level, workspace_id: workspace_id}}},
        _opts
      )
      when level in [:event, :workspace] and is_binary(workspace_id) do
    roles = MembershipContext.role_names(actor, workspace_id)

    case level do
      :event -> Enum.any?(roles, &Role.manage_role?/1)
      :workspace -> :owner in roles
    end
  end

  def match?(_actor, _context, _opts), do: false
end
