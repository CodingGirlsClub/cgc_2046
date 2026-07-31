defmodule Cgc2046Web.InvitationsController do
  @moduledoc """
  Invitation REST 端点。

  - `POST /api/v1/workspaces/:workspace_id/invitations` — 生成邀请链接(T05,
    spec §12)。授权:`invitation:create`(Owner/Admin/Volunteer);**Volunteer
    生成的邀请不可预授权 Admin 级角色**(Owner/Admin,生成时校验,超权 403)。
  - `POST /api/v1/workspaces/:workspace_id/invitations/consume` — 消费邀请链接
    (T06)。凭 `token`(明文)校验 active/过期/target_email/预授权角色(消费侧
    兜底校验),通过后创建 membership + 分配预授权角色并置 used。
  - `POST /api/v1/workspaces/:workspace_id/invitations/:id/revoke` — 撤销邀请
    (T06,`invitation:create`)。置 revoked,撤销后立即失效。

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

  # T06 消费邀请链接:凭明文 token(不落库,hash 匹配)。
  def consume(conn, params) do
    input =
      Ash.ActionInput.for_action(Invitation, :consume, %{plain_token: params["token"]},
        actor: actor(conn),
        tenant: tenant(conn)
      )

    handle_ash_result(conn, Ash.run_action(input), fn %{invitation: invitation} ->
      conn
      |> put_status(200)
      |> json(%{invitation: invitation_json(invitation)})
    end)
  end

  # T06 撤销邀请链接:置 revoked,撤销后立即失效。
  def revoke(conn, params) do
    case Ash.get(Invitation, params["id"], actor: actor(conn), tenant: tenant(conn)) do
      {:ok, invitation} ->
        changeset =
          Ash.Changeset.for_update(invitation, :revoke, %{},
            actor: actor(conn),
            tenant: tenant(conn)
          )

        handle_ash_result(conn, Ash.update(changeset), fn inv ->
          conn
          |> put_status(200)
          |> json(%{invitation: invitation_json(inv)})
        end)

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
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
