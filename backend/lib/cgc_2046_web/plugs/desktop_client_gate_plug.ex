defmodule Cgc2046Web.Plugs.DesktopClientGatePlug do
  @moduledoc """
  桌面客户端版本门控与止损开关 Plug（ADR-0027）。

  无状态、零 DB 依赖，挂载在 `:graphql`、`:mcp`（豁免 `DELETE /mcp/token`）
  与 `:llm_gateway`（`desktop_only: true`）最前端（鉴权之前），通过环境配置即时拦截：
  1. `kill_switch`：紧急止损桌面端（`:llm_gateway` 下连无头旧内测包一并阻断）。
  2. `blocked_versions`：精确停用缺陷版本。
  3. `min_supported_version`：基于 SemVer（`Version.compare/2`）强制升级最低版本。

  拒绝一律返回 HTTP `426 Upgrade Required`（JSON `%{error: %{code, message, min_version, download_url}}`），
  与鉴权失败 `401` 物理隔离，避免客户端误触发登出或清本地凭证。
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @default_download_url "https://github.com/CodingGirlsClub/cgc_2046/releases/latest"
  @telemetry_event [:cgc_2046, :desktop_gate, :rejected]

  @impl true
  def init(opts) do
    %{
      desktop_only: Keyword.get(opts, :desktop_only, false),
      exempt_token_delete: Keyword.get(opts, :exempt_token_delete, false)
    }
  end

  @impl true
  def call(conn, opts) do
    if exempt_request?(conn, opts) do
      conn
    else
      evaluate(conn, opts)
    end
  end

  @doc """
  从环境变量 map 解析 `:desktop_client_gate` 运行时配置（与 `load_config/0` 共用同一组规范化函数）。
  """
  @spec parse_env(%{optional(String.t()) => String.t()}) :: keyword()
  def parse_env(env) when is_map(env) do
    [
      kill_switch: truthy_flag?(Map.get(env, "DESKTOP_KILL_SWITCH")),
      kill_switch_message: normalize_blank(Map.get(env, "DESKTOP_KILL_SWITCH_MESSAGE")),
      min_supported_version: normalize_blank(Map.get(env, "DESKTOP_MIN_SUPPORTED_VERSION")),
      blocked_versions: normalize_blocked_versions(Map.get(env, "DESKTOP_BLOCKED_VERSIONS")),
      download_url: normalize_blank(Map.get(env, "DESKTOP_DOWNLOAD_URL")) || @default_download_url
    ]
  end

  defp evaluate(conn, opts) do
    cfg = load_config()
    client_version = single_header(conn, "x-cgc-client-version")
    client_platform = single_header(conn, "x-cgc-client-platform")

    case gate_decision(conn, opts, cfg, client_version) do
      :allow ->
        conn

      {:reject, code, message} ->
        reject(conn, code, message, cfg, client_version, client_platform)
    end
  end

  defp exempt_request?(%Plug.Conn{method: "DELETE", request_path: "/mcp/token"}, %{
         exempt_token_delete: true
       }),
       do: true

  defp exempt_request?(_conn, _opts), do: false

  defp gate_decision(conn, opts, cfg, client_version) do
    cond do
      not desktop_client?(conn) ->
        if opts.desktop_only and cfg.kill_switch do
          {:reject, "desktop_client_disabled", kill_switch_message(cfg)}
        else
          :allow
        end

      cfg.kill_switch ->
        {:reject, "desktop_client_disabled", kill_switch_message(cfg)}

      is_binary(client_version) and client_version in cfg.blocked_versions ->
        {:reject, "client_version_blocked", "当前桌面客户端版本已停用，请下载安装最新版本后继续使用。"}

      below_min_version?(client_version, cfg.min_supported_version) ->
        {:reject, "client_upgrade_required", "当前桌面客户端版本过旧，请升级至最新版本后继续使用。"}

      true ->
        :allow
    end
  end

  defp desktop_client?(conn) do
    single_header(conn, "x-cgc-client") == "desktop"
  end

  defp below_min_version?(_client_version, nil), do: false

  defp below_min_version?(client_version, min_supported_version) do
    case Version.parse(min_supported_version) do
      {:ok, min_v} ->
        case parse_client_version(client_version) do
          {:ok, client_v} -> Version.compare(client_v, min_v) == :lt
          :error -> true
        end

      :error ->
        Logger.warning(
          "Invalid DESKTOP_MIN_SUPPORTED_VERSION configuration: #{inspect(min_supported_version)}; skipping minimum version check"
        )

        false
    end
  end

  defp parse_client_version(version) when is_binary(version) and version != "" do
    Version.parse(version)
  end

  defp parse_client_version(_), do: :error

  defp reject(conn, code, message, cfg, client_version, client_platform) do
    :telemetry.execute(@telemetry_event, %{count: 1}, %{
      code: code,
      client_version: client_version,
      client_platform: client_platform,
      path: conn.request_path
    })

    Logger.warning(
      "desktop_client_gate rejected request code=#{code} path=#{conn.request_path} version=#{inspect(client_version)} platform=#{inspect(client_platform)}"
    )

    body =
      Jason.encode!(%{
        error: %{
          code: code,
          message: message,
          min_version: cfg.min_supported_version,
          download_url: cfg.download_url
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(426, body)
    |> halt()
  end

  defp load_config do
    raw = Application.get_env(:cgc_2046, :desktop_client_gate, [])

    %{
      kill_switch: truthy_flag?(Keyword.get(raw, :kill_switch, false)),
      kill_switch_message: normalize_blank(Keyword.get(raw, :kill_switch_message)),
      min_supported_version: normalize_blank(Keyword.get(raw, :min_supported_version)),
      blocked_versions: normalize_blocked_versions(Keyword.get(raw, :blocked_versions, [])),
      download_url: normalize_blank(Keyword.get(raw, :download_url)) || @default_download_url
    }
  end

  defp truthy_flag?(true), do: true

  defp truthy_flag?(value) when is_binary(value) do
    normalize_blank(value) in ["true", "1"]
  end

  defp truthy_flag?(_), do: false

  defp normalize_blocked_versions(versions) when is_list(versions) do
    versions
    |> Enum.map(&normalize_blank/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_blocked_versions(versions) when is_binary(versions) do
    versions
    |> String.split(",")
    |> normalize_blocked_versions()
  end

  defp normalize_blocked_versions(_), do: []

  defp kill_switch_message(%{kill_switch_message: msg}) when is_binary(msg), do: msg
  defp kill_switch_message(_), do: "桌面客户端当前暂停服务，请稍后重试或关注更新通知。"

  defp single_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> normalize_blank(value)
      _ -> nil
    end
  end

  defp normalize_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_blank(_), do: nil
end
