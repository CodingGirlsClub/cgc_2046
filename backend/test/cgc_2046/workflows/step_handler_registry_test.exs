defmodule Cgc2046.Workflows.StepHandlerRegistryTest do
  use ExUnit.Case, async: false

  alias Cgc2046.Workflows.StepHandlerRegistry
  alias Cgc2046.Workflows.TestActions

  # /check SC2-011：注册表表 owner 必须是长命进程（registry GenServer，Application 启动时创建）。
  # 旧实现 on-demand 建表，表归首个调用进程所有——短命调用进程死亡即销毁全部注册，
  # allowed? 恒 false，引擎拒绝一切 auto 步骤。
  test "registrations survive caller process death (SC2-011)" do
    # 首个调用者是短命进程：旧实现表归它所有，死亡即销毁
    pid =
      spawn(fn ->
        StepHandlerRegistry.register(TestActions.Uppercase)
      end)

    # 等短命进程退出（#27：不用 Process.sleep——AGENTS.md 要求 monitor/DOWN）
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert StepHandlerRegistry.allowed?(TestActions.Uppercase)
  end

  test "register is idempotent" do
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.Uppercase)
    assert StepHandlerRegistry.allowed?(TestActions.Uppercase)
  end

  test "unregistered module not allowed" do
    refute StepHandlerRegistry.allowed?(Jido.Tools.Files.WriteFile)
  end
end
