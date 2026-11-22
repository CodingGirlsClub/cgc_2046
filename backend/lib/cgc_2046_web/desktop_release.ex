defmodule Cgc2046Web.DesktopRelease do
  @moduledoc """
  桌面端发行配置解析与版本门控判定（ADR-0027）。

  无状态、零 DB 依赖，由 `DesktopClientGatePlug` 与 `DesktopVersionController` 共用：
  - `kill_switch`：紧急止损开关；
  - `blocked_versions`：精确停用缺陷版本列表；
  - `min_supported_version`：基于 SemVer（`Version.compare/2`）强制升级最低版本；
  - `latest_version` / `download_url` / `release_notes`：用于非强制新版本提示与引导下载。
  """

  require Logger

  @default_download_url "https://github.com/CodingGirlsClub/cgc_2046/releases"
  @default_kill_switch_message "桌面客户端当前暂停服务，请稍后重试或关注更新通知。"
  @default_blocked_message "当前桌面客户端版本已停用，请下载安装最新版本后继续使用。"
  @default_upgrade_message "当前桌面客户端版本过旧，请升级至最新版本后继续使用。"

  @type gate_result :: :allow | {:reject, String.t(), String.t()}

  @spec default_download_url() :: String.t()
  def default_download_url, do: @default_download_url

  @doc """
  从环境变量 map 解析 `:desktop_client_gate` 运行时配置（与 `config/0` 共用规范化逻辑）。
  """
  @spec parse_env(%{optional(String.t()) => String.t() | nil}) :: keyword()
  def parse_env(env) when is_map(env) do
    normalize_keyword(
      kill_switch: Map.get(env, "DESKTOP_KILL_SWITCH"),
      kill_switch_message: Map.get(env, "DESKTOP_KILL_SWITCH_MESSAGE"),
      min_supported_version: Map.get(env, "DESKTOP_MIN_SUPPORTED_VERSION"),
      blocked_versions: Map.get(env, "DESKTOP_BLOCKED_VERSIONS"),
      latest_version: Map.get(env, "DESKTOP_LATEST_VERSION"),
      download_url: Map.get(env, "DESKTOP_DOWNLOAD_URL"),
      release_notes: Map.get(env, "DESKTOP_RELEASE_NOTES")
    )
  end

  @doc """
  读取并规范化 `:cgc_2046, :desktop_client_gate`（兼容 `:desktop_release`）应用配置。
  """
  @spec config() :: map()
  def config do
    raw =
      case Application.get_env(:cgc_2046, :desktop_client_gate) do
        nil -> Application.get_env(:cgc_2046, :desktop_release, [])
        gate -> gate
      end

    raw |> normalize_keyword() |> Map.new()
  end

  @doc """
  判定桌面端版本号是否允许通过门控（kill_switch > blocked_versions > min_supported_version）。
  """
  @spec evaluate_gate(String.t() | nil, map()) :: gate_result()
  def evaluate_gate(client_version, cfg \\ config()) do
    cond do
      cfg.kill_switch ->
        {:reject, "desktop_client_disabled",
         cfg.kill_switch_message || @default_kill_switch_message}

      is_binary(client_version) and client_version in cfg.blocked_versions ->
        {:reject, "client_version_blocked", @default_blocked_message}

      below_min_version?(client_version, cfg.min_supported_version) ->
        {:reject, "client_upgrade_required", @default_upgrade_message}

      true ->
        :allow
    end
  end

  @doc """
  生成 `GET /api/desktop/version` 的响应载荷；`update_available` 与 `upgrade_required` 独立计算。
  """
  @spec version_status(String.t() | nil, map()) :: map()
  def version_status(client_version, cfg \\ config()) do
    update_available = update_available?(client_version, cfg.latest_version)

    {upgrade_required, code, message} =
      case evaluate_gate(client_version, cfg) do
        :allow -> {false, nil, nil}
        {:reject, reject_code, reject_message} -> {true, reject_code, reject_message}
      end

    %{
      latest_version: cfg.latest_version,
      min_supported_version: cfg.min_supported_version,
      download_url: cfg.download_url,
      release_notes: cfg.release_notes,
      kill_switch: cfg.kill_switch,
      update_available: update_available,
      upgrade_required: upgrade_required,
      code: code,
      message: message
    }
  end

  @doc false
  @spec single_header(Plug.Conn.t(), String.t()) :: String.t() | nil
  def single_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value] -> normalize_blank(value)
      _ -> nil
    end
  end

  @doc false
  @spec normalize_blank(term()) :: String.t() | nil
  def normalize_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_blank(_), do: nil

  defp normalize_keyword(raw) do
    [
      kill_switch: truthy_flag?(Keyword.get(raw, :kill_switch)),
      kill_switch_message: normalize_blank(Keyword.get(raw, :kill_switch_message)),
      min_supported_version: normalize_blank(Keyword.get(raw, :min_supported_version)),
      blocked_versions: normalize_blocked_versions(Keyword.get(raw, :blocked_versions, [])),
      latest_version: normalize_blank(Keyword.get(raw, :latest_version)),
      download_url: normalize_blank(Keyword.get(raw, :download_url)) || @default_download_url,
      release_notes: normalize_blank(Keyword.get(raw, :release_notes))
    ]
  end

  defp below_min_version?(_client_version, nil), do: false

  defp below_min_version?(client_version, min_supported_version) do
    case Version.parse(min_supported_version) do
      {:ok, min_v} ->
        case parse_semver(client_version) do
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

  defp update_available?(client_version, latest_version)
       when is_binary(client_version) and is_binary(latest_version) do
    with {:ok, latest_v} <- Version.parse(latest_version),
         {:ok, client_v} <- parse_semver(client_version) do
      Version.compare(latest_v, client_v) == :gt
    else
      _ -> false
    end
  end

  defp update_available?(_, _), do: false

  defp parse_semver(version) when is_binary(version) and version != "" do
    Version.parse(version)
  end

  defp parse_semver(_), do: :error

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
end
