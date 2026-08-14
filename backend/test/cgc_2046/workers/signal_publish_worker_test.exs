defmodule Cgc2046.Workers.SignalPublishWorkerTest do
  @moduledoc """
  E-9 #124 信号发布投递 worker 测试：perform 成功/失败路径 + 事务内入队。
  """

  use Cgc2046Web.ConnCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Workers.SignalPublishWorker

  test "perform 经内存总线发布成功返回 :ok" do
    assert :ok =
             perform_job(SignalPublishWorker, %{
               "signal_type" => "event.ended",
               "data" => %{"event_id" => Ecto.UUID.generate(), "title" => "t"},
               "tenant" => Ecto.UUID.generate()
             })
  end

  test "enqueue_in_transaction 插入 job（args JSON 安全）" do
    id = Ecto.UUID.generate()
    tenant = Ecto.UUID.generate()

    assert :ok =
             SignalPublishWorker.enqueue_in_transaction(
               "event.ended",
               %{"event_id" => id, "title" => "t"},
               tenant
             )

    assert_enqueued(
      worker: SignalPublishWorker,
      args: %{"signal_type" => "event.ended", "data" => %{"event_id" => id}, "tenant" => tenant}
    )
  end

  test "投递通道不可用（bus 宕机）→ perform 返回 {:error} 交 Oban 重试" do
    # 事务性 outbox 的失败面（plan 2026-08-14-003 Q6）：生产侧 action 不再接触
    # 总线，投递失败统一在 worker 经 Oban 重试（max_attempts 8）兜底。
    bus_id = Cgc2046.Workflows.JidoAdapter.bus_name()
    assert :ok = Supervisor.terminate_child(Cgc2046.Supervisor, bus_id)

    try do
      assert {:error, :not_found} =
               perform_job(SignalPublishWorker, %{
                 "signal_type" => "event.ended",
                 "data" => %{"event_id" => Ecto.UUID.generate(), "title" => "t"},
                 "tenant" => Ecto.UUID.generate()
               })
    after
      assert {:ok, _pid} = Supervisor.restart_child(Cgc2046.Supervisor, bus_id)
    end
  end
end
