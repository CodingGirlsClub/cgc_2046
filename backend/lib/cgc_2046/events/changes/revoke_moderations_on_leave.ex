defmodule Cgc2046.Events.Changes.RevokeModerationsOnLeave do
  @moduledoc """
  成员离台级联撤销其主理人指派（#561：#558「主理人 ⇒ 成员」不变量的反向承载）。

  挂在 `WorkspaceMembership.destroy` 的 after_action（同事务）：删除该
  workspace 下该用户的全部 `event_moderators` 行，每行落一条
  `AdminActionLog :event_moderator_remove`（metadata 带 `cascade:
  "membership_destroy"` 与主动撤销区分）。失败上抛整事务回滚——成员移除
  与指派撤销原子生效，不留「已离台但仍能核销」的窗口。

  跨域写面说明：Events 拥有 event_moderators 表，本 change 由 Accounts 的
  WorkspaceMembership.destroy 引用——写边界在资源 action 上（与 #558 的
  资源级校验同哲学），未来任何成员移除入口（产品面/console/AshAdmin）
  自动继承。Owner/Admin 的核销权走 `Rbac.manage?/2` 分支，不受本级联影响。
  """

  use Ash.Resource.Change

  alias Cgc2046.Accounts.AdminActionLog

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn cs, membership ->
      actor = get_in(cs.context, [:private, :actor])
      revoke!(membership, actor)
      {:ok, membership}
    end)
  end

  defp revoke!(membership, actor) do
    %{rows: rows} =
      Cgc2046.Repo.query!(
        """
        DELETE FROM event_moderators
        WHERE workspace_id = $1 AND user_id = $2
        RETURNING id::text, event_id::text
        """,
        [
          Cgc2046.Repo.uuid!(membership.workspace_id),
          Cgc2046.Repo.uuid!(membership.user_id)
        ]
      )

    for [_id, event_id] <- rows do
      AdminActionLog.log!(%{
        actor_id: actor && Map.get(actor, :id),
        action: :event_moderator_remove,
        target_type: :event,
        target_id: event_id,
        metadata: %{
          "user_id" => membership.user_id,
          "event_id" => event_id,
          "cascade" => "membership_destroy"
        }
      })
    end

    :ok
  end
end
