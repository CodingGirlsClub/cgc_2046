defmodule Cgc2046.Workflows.StepHandlerRegistry do
  @moduledoc """
  Step handler 注册表（ADR-0003 两阶段初始化 + /check SC2-001/SC2-011 修复）。

  引擎只执行**显式注册**的 step handler 模块。node_def 的 `action` 字符串指向的模块
  必须经 `register/1` 注册，否则 `build_workflow` 拒绝——杜绝租户用 node_def 让引擎
  执行任意 Jido.Action（如 `Jido.Tools.Files.WriteFile` → 任意宿主文件读写）。

  阶段一（注册期）：业务 step handler 模块启动时 `register/1` 声明契约；
  阶段二（运行期）：引擎 `allowed?/1` 校验后调用。引擎永远不 import 业务模块，
  只查注册表（ADR-0003「核心是协议不是框架」）。

  ## 表生命周期（SC2-011）

  表由本模块的 GenServer（`Cgc2046.Application` 启动时挂载）创建并持有——长命进程，
  短命调用进程（如请求 handler）死亡不影响注册。旧实现 on-demand 建表，表归首个
  调用进程所有，进程死亡即销毁全部注册。

  阶段 2 无生产 handler（真实 workflow 在 #39 实例化），注册表为空即拒绝一切
  auto 步骤；测试在 setup 注册 `Cgc2046.Workflows.TestActions.*`。
  """

  use GenServer

  @table :cgc_step_handler_registry

  @doc false
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker,
      restart: :permanent
    }
  end

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # 表由本 GenServer 持有（长命进程），进程死亡即销毁——注册不随调用进程丢失
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @doc "注册 step handler 模块（幂等）"
  @spec register(module()) :: :ok
  def register(mod) when is_atom(mod) do
    :ets.insert(@table, {mod})
    :ok
  end

  @doc "模块是否已注册为 step handler"
  @spec allowed?(module()) :: boolean()
  def allowed?(mod) when is_atom(mod) do
    :ets.member(@table, mod)
  end

  @doc "已注册的 handler 列表（调试/测试用）"
  @spec registered() :: [module()]
  def registered do
    :ets.tab2list(@table) |> Enum.map(&elem(&1, 0))
  end
end
