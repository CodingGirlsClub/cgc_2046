defmodule Cgc2046.LlmGateway.AffinityStore do
  @moduledoc """
  长命进程持有 `AffinityRouter` 的 ETS 表，避免把表建在短命调用进程里。
  `AffinityRouter.setup!/0` 仍可幂等调用（测试/独立脚本场景）。
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :ok = Cgc2046.LlmGateway.AffinityRouter.setup!()
    {:ok, %{}}
  end
end
