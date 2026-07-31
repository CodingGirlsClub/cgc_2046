defmodule Cgc2046Web.ProfilesController do
  @moduledoc """
  Profile REST 端点(T06,spec §13):成员公开资料,租户内可见。

  - `GET /api/v1/workspaces/:workspace_id/profiles` — 成员资料列表
    (MemberOfWorkspace 可见)
  - `GET /api/v1/workspaces/:workspace_id/profiles/:user_id` — 单个成员资料
  - `POST /api/v1/workspaces/:workspace_id/profiles` — 创建本人资料
    (自动绑定 actor 为 user_id;每成员每租户一条)
  - `PATCH /api/v1/workspaces/:workspace_id/profiles/:user_id` — 更新本人资料
  - `DELETE /api/v1/workspaces/:workspace_id/profiles/:user_id` — 删除本人资料

  授权:读 = 成员可见;写 = 本人(资源 policy + before_action 兜底),
  控制器只做错误契约翻译(§5)。
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Workspaces.Profile

  import Cgc2046Web.ApiHelpers

  def index(conn, _params) do
    actor = actor(conn)
    tenant = tenant(conn)

    case Ash.read(Profile, actor: actor, tenant: tenant) do
      {:ok, profiles} ->
        conn
        |> put_status(200)
        |> json(%{profiles: Enum.map(profiles, &profile_json/1)})

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  def show(conn, params) do
    actor = actor(conn)
    tenant = tenant(conn)

    case profile_by_user(tenant, params["user_id"], actor) do
      :not_found ->
        send_not_found(conn)

      {:ok, profile} ->
        conn
        |> put_status(200)
        |> json(%{profile: profile_json(profile)})

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  def create(conn, params) do
    actor = actor(conn)
    tenant = tenant(conn)

    attrs = pick_attrs(params, ["avatar_url", "bio", "tags", "portfolio"])

    changeset = Ash.Changeset.for_create(Profile, :create, attrs, actor: actor, tenant: tenant)

    handle_ash_result(conn, Ash.create(changeset), fn profile ->
      conn
      |> put_status(201)
      |> json(%{profile: profile_json(profile)})
    end)
  end

  def update(conn, params) do
    actor = actor(conn)
    tenant = tenant(conn)

    case profile_by_user(tenant, params["user_id"], actor) do
      :not_found ->
        send_not_found(conn)

      {:ok, profile} ->
        attrs = pick_attrs(params, ["avatar_url", "bio", "tags", "portfolio"])

        changeset =
          Ash.Changeset.for_update(profile, :update, attrs, actor: actor, tenant: tenant)

        handle_ash_result(conn, Ash.update(changeset), fn p ->
          conn
          |> put_status(200)
          |> json(%{profile: profile_json(p)})
        end)

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  def delete(conn, params) do
    actor = actor(conn)
    tenant = tenant(conn)

    case profile_by_user(tenant, params["user_id"], actor) do
      :not_found ->
        send_not_found(conn)

      {:ok, profile} ->
        changeset = Ash.Changeset.for_destroy(profile, :destroy, %{}, actor: actor, tenant: tenant)

        handle_ash_result(conn, Ash.destroy(changeset), fn _ ->
          send_resp(conn, 204, "")
        end)

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  # 按 user_id 查 Profile(一个成员一个 Profile;不存在 → 404)
  defp profile_by_user(tenant, user_id, actor) do
    import Ash.Query, only: [filter: 2]

    case Profile
         |> filter(user_id == ^user_id)
         |> Ash.read_one(actor: actor, tenant: tenant) do
      {:ok, nil} -> :not_found
      other -> other
    end
  end

  defp profile_json(profile) do
    %{
      id: profile.id,
      workspace_id: profile.workspace_id,
      user_id: profile.user_id,
      avatar_url: profile.avatar_url,
      bio: profile.bio,
      tags: profile.tags,
      portfolio: profile.portfolio,
      created_at: profile.inserted_at,
      updated_at: profile.updated_at
    }
  end
end
