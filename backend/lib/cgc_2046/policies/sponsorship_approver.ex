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

  # 拍板 #4 的审批人规则唯一真源：Event 级 = 目标工作台管理角色（
  # `Role.manage_roles/0`，owner/admin，角色清单变更自动跟随）；Workspace 级 =
  # **仅 Owner**（长期承诺加严；平台 Admin 备案二期，不参与审批）。
  #
  # 三消费面（只改此处即全链路跟随）：
  # - 写面：`match?/3`（approve/reject policy）；
  # - 提醒面：`ApprovalReminderWorker` 每工作台两套收件人选择器按 `{:roles,
  #   approver_roles(level)}` 派生；
  # - 读面：`PendingApprovals` 按角色集反查 allowed_levels 做赞助行级过滤。
  @spec approver_roles(:event | :workspace) :: [atom()]
  def approver_roles(:event), do: Role.manage_roles()
  def approver_roles(:workspace), do: [:owner]

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
    Enum.any?(roles, &(&1 in approver_roles(level)))
  end

  def match?(_actor, _context, _opts), do: false
end
