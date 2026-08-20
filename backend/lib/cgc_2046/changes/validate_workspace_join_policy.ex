defmodule Cgc2046.Changes.ValidateWorkspaceJoinPolicy do
  @moduledoc """
  校验目标工作台的 join_policy 是否为 :request。

  由 `JoinRequest.create` action 调用：申请人自助创建加入申请时，
  确保目标工作台允许申请加入（join_policy == :request）。
  open 策略应走直接加入（:join action），invite_only 应走邀请链接。

  拒绝时抛 `Cgc2046.Errors.BusinessError`（稳定 code，#206）：
  join_policy 为 open/invite_only 或工作台不存在时，调用方（GraphQL/web）
  依据 code 渲染可读文案，而非此前的空 Forbidden（errors: []）。
  """
  use Ash.Resource.Change

  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Errors.BusinessError

  @impl true
  def change(changeset, _opts, _context) do
    workspace_id = Ash.Changeset.get_attribute(changeset, :workspace_id)

    if workspace_id do
      case Ash.get(Workspace, workspace_id, authorize?: false) do
        {:ok, %{join_policy: :request}} ->
          changeset

        {:ok, %{join_policy: :open}} ->
          changeset
          |> Ash.Changeset.add_error(
            BusinessError.exception(
              message: "This workspace is open to join directly",
              code: "join_request_open",
              fields: [:workspace_id]
            )
          )

        {:ok, _workspace} ->
          changeset
          |> Ash.Changeset.add_error(
            BusinessError.exception(
              message: "This workspace is invite-only",
              code: "join_request_invite_only",
              fields: [:workspace_id]
            )
          )

        {:error, _reason} ->
          changeset
          |> Ash.Changeset.add_error(
            BusinessError.exception(
              message: "Workspace not found",
              code: "join_request_not_found",
              fields: [:workspace_id]
            )
          )
      end
    else
      changeset
    end
  end
end
