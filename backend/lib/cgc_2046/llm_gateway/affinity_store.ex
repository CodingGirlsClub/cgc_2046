defmodule Cgc2046.LlmGateway.AffinityStore do
  @moduledoc """
  长命进程持有 `AffinityRouter` 的 ETS 表，避免把表建在短命调用进程里，并周期性
  清理过期会话粘性条目，防止 ETS 表随会话数持续增长。
  `AffinityRouter.setup!/0` 仍可幂等调用（测试/独立脚本场景）。
  """

  use GenServer

  alias Cgc2046.LlmGateway.AffinityRouter

  @default_cleanup_interval_ms 600_000

  def start_link(opts \\ []) when is_list(opts) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    :ok = AffinityRouter.setup!()
    interval_ms = Keyword.get(opts, :cleanup_interval_ms, @default_cleanup_interval_ms)
    timer_ref = schedule_cleanup(interval_ms)
    {:ok, %{cleanup_interval_ms: interval_ms, timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:cleanup, %{cleanup_interval_ms: interval_ms} = state) do
    if is_reference(Map.get(state, :timer_ref)) do
      Process.cancel_timer(state.timer_ref)
    end

    AffinityRouter.cleanup_expired!()
    timer_ref = schedule_cleanup(interval_ms)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  defp schedule_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup, interval_ms)
  end
end
