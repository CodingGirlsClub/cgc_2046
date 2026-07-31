defmodule Cgc2046Web.ApiTokensController do
  @moduledoc """
  `POST /api/v1/workspaces/:workspace_id/api_tokens` 与
  `POST /api/v1/workspaces/:workspace_id/api_tokens/:id/revoke`(T07)。

  签发:workspace 成员为自己签发 ApiToken(机器凭证,spec §3 / 用户故事 50)。
  - body: `name`(必填)、`scopes`(数组,可选,默认 ["read"];合法
    read / workflow:write / agent:write)、`expires_in_days`(可选,默认 30)
  - 平台只存 token_hash(SHA-256),**明文只在响应中出现一次**
  - 授权由 ApiToken `:issue` action 完成(Rbac.member? + user_id 强制)

  撤销:仅 token 属主本人(用户故事 51"一键撤销立即全局失效")。撤销 =
  `revoked_at` 置位,每请求白名单校验即时全局失效。
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Workspaces.ApiToken

  import Cgc2046Web.ApiHelpers

  def create(conn, params) do
    case build_issue_attrs(conn, params) do
      {:ok, attrs} ->
        case ApiToken.issue(actor(conn), attrs) do
          {:ok, record, plain_token} ->
            conn
            |> put_status(201)
            |> json(%{
              token: plain_token,
              api_token: json_record(record, [:id, :name, :scopes, :workspace_id, :expires_at, :inserted_at])
            })

          {:error, %Ash.Error.Forbidden{}} ->
            send_error(conn, 403, "Forbidden")

          {:error, %Ash.Error.Invalid{} = error} ->
            send_error(conn, 422, invalid_message(error))

          {:error, error} ->
            send_error(conn, 400, Exception.message(error))
        end

      {:error, status, message} ->
        send_error(conn, status, message)
    end
  end

  def revoke(conn, %{"id" => id}) do
    result =
      with {:ok, api_token} <- load_token(conn, id),
           {:ok, updated} <- revoke_token(conn, api_token) do
        {:ok, updated}
      end

    case result do
      {:ok, api_token} ->
        json(conn, %{
          api_token: json_record(api_token, [:id, :name, :workspace_id, :revoked_at])
        })

      {:error, :not_found} ->
        send_not_found(conn)

      {:error, %Ash.Error.Forbidden{}} ->
        send_error(conn, 403, "Forbidden")

      {:error, error} ->
        send_error(conn, 400, Exception.message(error))
    end
  end

  # ---------- helpers ----------

  defp build_issue_attrs(conn, params) do
    workspace_id = tenant(conn)
    name = params["name"]
    scopes = params["scopes"] || ["read"]
    expires_in_days = params["expires_in_days"] || ApiToken.default_ttl_days()

    with {:ok, scopes} <- normalize_scopes(scopes),
         {:ok, expires_at} <- compute_expires_at(expires_in_days) do
      {:ok,
       %{
         name: name,
         scopes: scopes,
         expires_at: expires_at,
         workspace_id: workspace_id
       }}
    end
  end

  defp normalize_scopes(scopes) when is_list(scopes) do
    if Enum.all?(scopes, &(&1 in ApiToken.valid_scopes())) do
      {:ok, scopes}
    else
      {:error, 422, "invalid scopes (allowed: #{Enum.join(ApiToken.valid_scopes(), ", ")})"}
    end
  end

  defp normalize_scopes(_), do: {:error, 422, "scopes must be an array"}

  defp compute_expires_at(days) when is_integer(days) and days > 0 do
    {:ok, DateTime.add(DateTime.utc_now(), days, :day)}
  end

  defp compute_expires_at(_), do: {:error, 422, "expires_in_days must be a positive integer"}

  # 加载 token(不受 read policy 拦截,授权交给 :revoke update 的属主校验,
  # 保证非属主得到 403 而非 404 —— spec §3 撤销仅本人,属主判定在 update 层)
  defp load_token(_conn, id) do
    case Ash.get(ApiToken, id, authorize?: false) do
      {:ok, api_token} -> {:ok, api_token}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp revoke_token(conn, api_token) do
    Ash.update(api_token, %{}, action: :revoke, actor: actor(conn))
  end

  defp invalid_message(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, "; ", &Exception.message/1)
  end
end
