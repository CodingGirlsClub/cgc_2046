defmodule Cgc2046Web.InvitationsController do
  @moduledoc """
  `POST /api/v1/workspaces/:workspace_id/invitations`:生成邀请链接(T05,spec §12)。

  授权:`invitation:create`(Owner/Admin/Volunteer)由 Invitation 资源 policy +
  写 action `Rbac.ensure!` 把关;**Volunteer 生成的邀请不可预授权 Admin 级角色**
  (Owner/Admin,生成时校验,超权 403)。

  明文 token 由服务端生成(`plain_token` argument,不落库),响应一次性返回;
  库中只存 SHA-256 hash。
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Workspaces.Invitation

  import Cgc2046Web.ApiHelpers

  def create(conn, params) do
    plain_token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    attrs =
      pick_attrs(params, ["expires_at", "target_email", "preauthorized_role_ids"])
      |> Map.put(:plain_token, plain_token)

    changeset =
      Ash.Changeset.for_create(Invitation, :create, attrs,
        actor: actor(conn),
        tenant: tenant(conn)
      )

    result = Ash.create(changeset)

    handle_ash_result(conn, result, fn invitation ->
      conn
      |> put_status(201)
      |> json(%{invitation: Map.put(invitation_json(invitation), :token, plain_token)})
    end)
  end

  defp invitation_json(invitation) do
    %{
      id: invitation.id,
      workspace_id: invitation.workspace_id,
      expires_at: invitation.expires_at,
      target_email: invitation.target_email,
      preauthorized_role_ids: invitation.preauthorized_role_ids,
      status: invitation.status,
      inviter_id: invitation.inviter_id,
      created_at: invitation.inserted_at
    }
  end
end
