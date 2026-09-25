defmodule Cgc2046.Notifications.DeliveryTest do
  @moduledoc """
  #847 钉测：Delivery.enqueue 的耐久语义——逐身份落行与入队（#3 同用户
  多身份不折叠）、幂等（同一幂等键重复入队只产生一行与一个 job）、零身份
  哨兵行（Q5：落一行可观测记录而非静默跳过）、事务失败 raise 且零残留。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Notifications.{Delivery, NotificationDelivery, Workers.DeliveryWorker}
  alias Cgc2046.Repo

  require Ash.Query

  defp deliveries_for(user_id) do
    NotificationDelivery
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
  end

  defp enqueue(user_id, identities, key \\ nil) do
    key = key || "delivery-test-#{System.unique_integer([:positive])}"

    :ok =
      Delivery.enqueue(
        {user_id, identities},
        "approval_result",
        %{"status" => "confirmed"},
        %{"idempotency_key" => key}
      )

    key
  end

  test "单身份入队 → 一行 pending + 一个 DeliveryWorker job（args 携带 delivery_id，data 原样落行）" do
    user = Fixtures.register_user("dt-single")
    enqueue(user.id, [%{provider: :wechat, uid: "dt-single-openid"}])

    [row] = deliveries_for(user.id)
    assert row.status == :pending
    assert row.platform == "wechat"
    assert row.identity_uid == "dt-single-openid"
    assert row.template_key == "approval_result"
    assert row.data == %{"status" => "confirmed"}

    assert [%{args: %{"delivery_id" => delivery_id}}] = all_enqueued(worker: DeliveryWorker)
    assert delivery_id == row.id
  end

  test "多身份各落一行（同用户多身份不折叠），幂等键逐身份不同" do
    user = Fixtures.register_user("dt-multi")

    enqueue(user.id, [
      %{provider: :wechat, uid: "dt-multi-a"},
      %{provider: :wechat, uid: "dt-multi-b"}
    ])

    rows = deliveries_for(user.id)
    assert length(rows) == 2
    assert rows |> Enum.map(& &1.identity_uid) |> Enum.sort() == ["dt-multi-a", "dt-multi-b"]
    assert rows |> Enum.map(& &1.idempotency_key) |> Enum.uniq() |> length() == 2
    assert length(all_enqueued(worker: DeliveryWorker)) == 2
  end

  test "同一幂等键重复入队 → 只一行、只一个 job" do
    user = Fixtures.register_user("dt-idem")
    identity = %{provider: :wechat, uid: "dt-idem-openid"}
    key = enqueue(user.id, [identity])

    :ok =
      Delivery.enqueue(
        {user.id, [identity]},
        "approval_result",
        %{"status" => "confirmed"},
        %{"idempotency_key" => key}
      )

    assert length(deliveries_for(user.id)) == 1
    assert length(all_enqueued(worker: DeliveryWorker)) == 1
  end

  test "已 sent 的行重复入队 → 不再插 job（upsert 不覆盖终态）" do
    user = Fixtures.register_user("dt-sent")
    identity = %{provider: :wechat, uid: "dt-sent-openid"}
    key = enqueue(user.id, [identity])

    [row] = deliveries_for(user.id)

    {:ok, _} =
      row
      |> Ash.Changeset.for_update(:mark_sent, %{}, authorize?: false)
      |> Ash.update()

    # 清空既有 job，使 Oban unique 无法兜底——本断言钉的正是 :sent 行的 no-requeue 分支
    Repo.delete_all(Oban.Job)

    :ok =
      Delivery.enqueue(
        {user.id, [identity]},
        "approval_result",
        %{"status" => "confirmed"},
        %{"idempotency_key" => key}
      )

    assert [%{status: :sent}] = deliveries_for(user.id)
    assert [] = all_enqueued(worker: DeliveryWorker)
  end

  test "零身份 → 哨兵行（platform/identity_uid 均为 nil、pending）+ 一个 job（Q5：可观测记录）" do
    user = Fixtures.register_user("dt-zero")
    enqueue(user.id, [])

    [row] = deliveries_for(user.id)
    assert is_nil(row.platform)
    assert is_nil(row.identity_uid)
    assert row.status == :pending

    assert [%{args: %{"delivery_id" => id}}] = all_enqueued(worker: DeliveryWorker)
    assert id == row.id
  end

  # 无效 user_id 在事务 fn 内触发 Ash cast 失败：Repo.transaction 对 fn 内异常
  # 是回滚后原样冒泡（不吞成 {:error, _}），调用方看到的就是 raise——
  # 「失败即 raise、零残留」的耐久路径语义。（delivery.ex:43 的 {:error, _}
  # 分支在 fn 无显式 rollback 时不可达，见 #847 汇报「可疑之处」。）
  test "事务失败 → 异常冒出且零残留" do
    assert_raise Ash.Error.Invalid, fn ->
      Delivery.enqueue(
        {"not-a-uuid", [%{provider: :wechat, uid: "dt-txn-openid"}]},
        "approval_result",
        %{},
        %{"idempotency_key" => "dt-txn"}
      )
    end

    assert [] = Ash.read!(NotificationDelivery, authorize?: false)
  end
end
