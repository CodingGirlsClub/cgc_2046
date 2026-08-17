defmodule Cgc2046.Workflows.SignalIdempotencyTest do
  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.Workflows.SignalIdempotency

  test "首次登记 :ok；同 (signal_type, idempotency_key) 再登记 :already_claimed" do
    assert :ok = SignalIdempotency.claim("enrollment.completed", "enrollment.completed:abc")

    assert {:error, :already_claimed} =
             SignalIdempotency.claim("enrollment.completed", "enrollment.completed:abc")
  end

  test "同 type 不同 key、同 key 不同 type 均可登记" do
    assert :ok = SignalIdempotency.claim("enrollment.completed", "enrollment.completed:def")
    assert :ok = SignalIdempotency.claim("enrollment.completed", "enrollment.completed:ghi")
    assert :ok = SignalIdempotency.claim("sponsorship.active", "enrollment.completed:def")
  end

  test "workspace_id 可空也可带，且不参与唯一性" do
    admin = Cgc2046.AccountsFixtures.platform_admin()
    workspace = Cgc2046.AccountsFixtures.create_workspace(admin)

    assert :ok = SignalIdempotency.claim("research.outline", "k1", workspace.id)
    assert {:error, :already_claimed} = SignalIdempotency.claim("research.outline", "k1")

    assert {:error, :already_claimed} =
             SignalIdempotency.claim("research.outline", "k1", workspace.id)
  end

  test "登记行可由 Ash read 读回（观测面）" do
    assert :ok = SignalIdempotency.claim("speaker.completed", "spk-1")

    assert [row] =
             SignalIdempotency
             |> Ash.Query.filter(
               signal_type == "speaker.completed" and idempotency_key == "spk-1"
             )
             |> Ash.read!(authorize?: false)

    assert row.signal_type == "speaker.completed"
    assert row.idempotency_key == "spk-1"
  end
end
