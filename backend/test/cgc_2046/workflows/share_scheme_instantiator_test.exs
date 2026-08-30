defmodule Cgc2046.Workflows.ShareSchemeInstantiatorTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Miniprogram.ShareSchemeWorker
  alias Cgc2046.Workflows.{ShareSchemeInstantiator, SignalSubscriber}

  # P3 订阅器契约（plan 011；curriculum instantiator / notification_subscriber 先例）：
  # 信号 → Oban 入队（外呼不进信号同步路径）；claim_first 幂等。

  test "patterns/0 声明 event.launched / course.launched" do
    assert ShareSchemeInstantiator.patterns() == ["event.launched", "course.launched"]
  end

  describe "deliver/2 → Oban 入队" do
    test "event.launched → ShareSchemeWorker 入队（kind=event）" do
      assert :ok =
               SignalSubscriber.deliver(ShareSchemeInstantiator, %{
                 type: "event.launched",
                 data: %{
                   "event_id" => "00000000-0000-4000-8000-00000000000e",
                   "idempotency_key" => "event.launched:test-1"
                 }
               })

      assert_enqueued(
        worker: ShareSchemeWorker,
        args: %{
          target_kind: "event",
          target_id: "00000000-0000-4000-8000-00000000000e"
        }
      )
    end

    test "course.launched → ShareSchemeWorker 入队（kind=course）" do
      assert :ok =
               SignalSubscriber.deliver(ShareSchemeInstantiator, %{
                 type: "course.launched",
                 data: %{
                   "course_id" => "00000000-0000-4000-8000-00000000000c",
                   "idempotency_key" => "course.launched:test-1"
                 }
               })

      assert_enqueued(
        worker: ShareSchemeWorker,
        args: %{
          target_kind: "course",
          target_id: "00000000-0000-4000-8000-00000000000c"
        }
      )
    end

    test "重复投递 → :duplicate 不再入队（claim_first）" do
      data = %{
        "event_id" => "00000000-0000-4000-8000-00000000000d",
        "idempotency_key" => "event.launched:test-2"
      }

      assert :ok =
               SignalSubscriber.deliver(ShareSchemeInstantiator, %{
                 type: "event.launched",
                 data: data
               })

      assert :duplicate =
               SignalSubscriber.deliver(ShareSchemeInstantiator, %{
                 type: "event.launched",
                 data: data
               })

      assert [%Oban.Job{}] = all_enqueued(worker: ShareSchemeWorker)
    end

    test "信号无 entity id → :ok 不入队（best-effort 不抛错）" do
      assert :ok =
               SignalSubscriber.deliver(ShareSchemeInstantiator, %{
                 type: "event.launched",
                 data: %{"idempotency_key" => "event.launched:test-3"}
               })

      assert [] = all_enqueued(worker: ShareSchemeWorker)
    end
  end
end
