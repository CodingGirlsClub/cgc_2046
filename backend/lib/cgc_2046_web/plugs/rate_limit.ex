defmodule Cgc2046Web.Plugs.RateLimit do
  @moduledoc """
  ETS 固定窗口限流器，作为 Absinthe middleware 使用。

  按 `"rate:REMOTE_IP:FIELD_VALUE"` 计数，窗口 15 分钟，上限 5 次。
  零依赖，单节点够用；多节点时把 ETS 换成 Redis 即可。

  ## 用法

      field :sign_in, :sign_in_result do
        middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:email])
        resolve(...)
      end
  """

  use GenServer

  @table :cgc_rate_limiter
  @window_seconds 900

  @doc false
  def table, do: @table

  @doc false
  def check(key, opts \\ []), do: check_rate(key, opts)

  @doc false
  def build_key(prefix, value, opts \\ []) when is_binary(prefix) do
    normalized = normalize_value(value, opts[:normalize])
    hashed = :crypto.hash(:sha256, to_string(normalized)) |> Base.encode16(case: :lower)
    "#{prefix}:#{hashed}"
  end

  defp max_attempts,
    do:
      Application.get_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, [])
      |> Keyword.get(:max_attempts, 5)

  # ── GenServer（仅用于启动时创建 ETS 表） ──────────────────────────

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    {:ok, %{}}
  end

  # ── Absinthe middleware ──────────────────────────────────────────

  @doc false
  def init(opts), do: opts

  @doc false
  def call(resolution, opts) do
    key = build_middleware_key(resolution, opts[:key_path] || [], opts)

    case check(key, opts) do
      :ok ->
        resolution

      :error ->
        Absinthe.Resolution.put_result(
          resolution,
          {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        )
    end
  end

  # ── 内部 ─────────────────────────────────────────────────────────

  defp build_middleware_key(resolution, key_path, opts) do
    remote_ip =
      case resolution.context do
        %{conn: %{remote_ip: ip}} -> ip |> :inet.ntoa() |> to_string()
        _ -> "unknown"
      end

    field_value =
      Enum.reduce(key_path, resolution.arguments, fn key, acc ->
        case acc do
          %{^key => val} -> val
          _ -> nil
        end
      end)

    build_key("rate:#{remote_ip}", field_value, opts)
  end

  defp normalize_value(value, normalizer) when is_function(normalizer, 1),
    do: normalizer.(value)

  defp normalize_value(value, _normalizer), do: value

  defp check_rate(key, opts) do
    now = System.system_time(:second)
    window_seconds = Keyword.get(opts, :window_seconds, @window_seconds)
    max_attempts = Keyword.get(opts, :max_attempts, max_attempts())

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start < window_seconds ->
        if count >= max_attempts do
          :error
        else
          # ponytail: update_counter/4 带默认值，防 lookup 与 update 间的竞态
          :ets.update_counter(@table, key, {2, 1}, {key, 0, now})
          :ok
        end

      _ ->
        :ets.insert(@table, {key, 1, now})
        :ok
    end
  end
end
