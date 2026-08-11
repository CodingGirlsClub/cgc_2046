defmodule Cgc2046.Changes.ValidateWorkspaceHasOwner do
  @moduledoc """
  校验目标工作台已有 Owner 就位（#115 ownerless 门控，方案 B）。

  由 `JoinRequest.create` action 调用（挂在 ValidateWorkspaceJoinPolicy 之后）：
  pending-owner（owner_email 邀请未接受）期间工作台无任何管理角色，
  申请提交后无人可审批（approve/reject 限工作台 Owner/Admin），只会挂着等
  approval_deadline 过期，故阻断。Owner 接受邀请入座后 owner_count > 0，
  门控自动解除。
  """
  use Ash.Resource.Change

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Workspace

  @impl true
  def change(changeset, _opts, _context) do
    workspace_id = Ash.Changeset.get_attribute(changeset, :workspace_id)

    if workspace_id do
      case Ash.get(Workspace, workspace_id, authorize?: false) do
        {:ok, %Workspace{}} ->
          if MembershipContext.owner_count(workspace_id) == 0 do
            changeset
            |> Ash.Changeset.add_error(
              Ash.Error.Changes.InvalidAttribute.exception(
                field: :workspace_id,
                message: "工作台尚未开放申请（Owner 未就位）"
              )
            )
          else
            changeset
          end

        _ ->
          # 工作台不存在：交由 ValidateWorkspaceJoinPolicy 的 Forbidden 分支报错，不重复加错
          changeset
      end
    else
      changeset
    end
  end
end
