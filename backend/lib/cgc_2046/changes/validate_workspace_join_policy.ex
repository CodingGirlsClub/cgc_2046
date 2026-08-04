defmodule Cgc2046.Changes.ValidateWorkspaceJoinPolicy do
  @moduledoc """
  校验目标工作台的 join_policy 是否为 :request。

  由 `JoinRequest.create` action 调用：申请人自助创建加入申请时，
  确保目标工作台允许申请加入（join_policy == :request）。
  open 策略应走直接加入（:join action），invite_only 应走邀请链接。
  """
  use Ash.Resource.Change

  alias Cgc2046.Accounts.Workspace

  @impl true
  def change(changeset, _opts, _context) do
    workspace_id = Ash.Changeset.get_attribute(changeset, :workspace_id)

    if workspace_id do
      case Ash.get(Workspace, workspace_id, authorize?: false) do
        {:ok, %{join_policy: :request}} ->
          changeset

        {:ok, _workspace} ->
          changeset
          |> Ash.Changeset.add_error(Ash.Error.Forbidden.exception([]))

        {:error, _reason} ->
          changeset
          |> Ash.Changeset.add_error(Ash.Error.Forbidden.exception([]))
      end
    else
      changeset
    end
  end
end
