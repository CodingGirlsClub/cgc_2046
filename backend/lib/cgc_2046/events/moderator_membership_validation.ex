defmodule Cgc2046.Events.ModeratorMembershipValidation do
  @moduledoc """
  主理人成员前提（#558 / #542 决策 A1，KD7 修订）：被指派者须已是目标
  Workspace 成员——「主理人不是成员」的前提废止（成员默认权限面极小：
  tutor/volunteer/learner 仅 view_workspace + access_invite_only，见
  `Accounts.Rbac`），外部合作者由「先邀请入台再指派」承载。

  挂在 `EventModerator.assign` 资源写边界（而非 `Moderators.assign/4` 域函数）：
  单点 fail-closed，覆盖域函数、`ensure_assigned/2`（建场创建者恒为
  Owner/Admin 成员）与未来一切调用面（AshAdmin/console/种子）。

  读失败与「非成员」不同桶：前者归 `database_error`（瞬断可重试，不误导
  操作者去重复邀请），后者才归 `event_moderator_not_workspace_member`。
  """

  use Ash.Resource.Validation

  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.Errors.BusinessError

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    workspace_id = Ash.Changeset.get_attribute(changeset, :workspace_id)

    case member?(user_id, workspace_id) do
      true -> :ok
      false -> {:error, not_member_error()}
      :error -> {:error, database_error()}
    end
  end

  defp member?(user_id, workspace_id) when is_binary(user_id) and is_binary(workspace_id) do
    case WorkspaceMembership
         |> Ash.Query.filter(user_id == ^user_id)
         |> Ash.read(authorize?: false, tenant: workspace_id) do
      {:ok, [_ | _]} -> true
      {:ok, []} -> false
      {:error, _} -> :error
    end
  end

  # 属性缺失由 changeset 自身的 allow_nil?: false 拦截，不在本校验职责内
  defp member?(_user_id, _workspace_id), do: true

  defp not_member_error do
    BusinessError.exception(
      message: "the assignee must be a member of this workspace first",
      code: "event_moderator_not_workspace_member",
      fields: [:user_id]
    )
  end

  defp database_error do
    BusinessError.exception(
      message: "database operation failed",
      code: "database_error",
      fields: [:user_id]
    )
  end
end
