defmodule Cgc2046.Workers.SignalPublishWorkerTest do
  @moduledoc """
  E-9 #124 信号发布投递 worker 测试：perform 成功路径 + 事务内入队。
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
end
