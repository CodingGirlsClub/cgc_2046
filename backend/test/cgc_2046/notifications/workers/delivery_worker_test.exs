defmodule Cgc2046.Notifications.Workers.DeliveryWorkerTest do
  @moduledoc """
  #556：DeliveryWorker 末拍终态化——pending_reason 类失败在 job 耗尽后
  不再滞留 pending（行落 :failed 带原因，规15 Finding 出报表）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Notifications.{Delivery, NotificationDelivery}
  alias Cgc2046.Notifications.Workers.DeliveryWorker

  require Ash.Query

  defp enqueue_delivery(user_id) do
    key = "delivery-worker-test-#{System.unique_integer([:positive])}"

    :ok =
      Delivery.enqueue(
        {user_id, [%{provider: :wechat, uid: "openid-#{key}"}]},
        "approval_result",
        %{},
        %{"idempotency_key" => key}
      )

    [row] =
      NotificationDelivery
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.read!(authorize?: false)

    row
  end

  test "末拍（attempt = max_attempts）pending_reason → 终态 failed，last_error 带原因" do
    user = Fixtures.register_user("dw-final")
    row = enqueue_delivery(user.id)

    # consent_exhausted 是 pending_reason（未订阅授权）——非末拍只重试不落终态；
    # 末拍（第 5 次，max_attempts=5）终态化
    assert {:error, :consent_exhausted} =
             perform_job(DeliveryWorker, %{"delivery_id" => row.id}, attempt: 5)

    reloaded = Ash.get!(NotificationDelivery, row.id, authorize?: false)
    assert reloaded.status == :failed
    assert reloaded.last_error =~ "consent_exhausted"
    assert reloaded.attempts == 1
  end

  test "非末拍 pending_reason → 仍 pending（重试语义不变）" do
    user = Fixtures.register_user("dw-retry")
    row = enqueue_delivery(user.id)

    assert {:error, :consent_exhausted} =
             perform_job(DeliveryWorker, %{"delivery_id" => row.id}, attempt: 2)

    reloaded = Ash.get!(NotificationDelivery, row.id, authorize?: false)
    assert reloaded.status == :pending
    assert reloaded.attempts == 0
  end

  test "已 sent 行幂等 no-op（不重复投递、不落终态）" do
    user = Fixtures.register_user("dw-sent")
    row = enqueue_delivery(user.id)

    {:ok, sent} =
      row
      |> Ash.Changeset.for_update(:mark_sent, %{}, authorize?: false)
      |> Ash.update()

    assert :ok = perform_job(DeliveryWorker, %{"delivery_id" => sent.id}, attempt: 5)
    assert Ash.get!(NotificationDelivery, row.id, authorize?: false).status == :sent
  end
end
