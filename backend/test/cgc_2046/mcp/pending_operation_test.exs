defmodule Cgc2046.Mcp.PendingOperationTest do
  @moduledoc """
  确认流 pending 操作（D8 two-tool 模式 / D-D3）资源行为测试。

  状态机：pending → confirmed | cancelled；expires_at 到点读时派生 expired（不落库）。
  无 confirm 不落库是调用方（Confirmation 模块）的纪律，本资源只管状态正确性。
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.Mcp.PendingOperation
  alias Cgc2046.AccountsFixtures, as: Fixtures

  defp pend(user, tool \\ "create_invitation") do
    PendingOperation
    |> Ash.Changeset.for_create(
      :pend,
      %{user_id: user.id, tool: tool, params: %{"workspace_id" => "abc"}, summary: "创建邀请"},
      authorize?: false
    )
    |> Ash.create()
  end

  describe "pend（创建 pending）" do
    test "创建成功：默认 pending，expires_at 默认约 10 分钟后" do
      user = Fixtures.register_user("pend-1")

      assert {:ok, op} = pend(user)
      assert op.status == :pending
      assert op.tool == "create_invitation"
      assert op.summary == "创建邀请"

      diff = DateTime.diff(op.expires_at, DateTime.utc_now(), :second)
      assert diff > 550 and diff <= 600
    end
  end

  describe "confirm" do
    test "本人确认 pending → confirmed + resolved_at" do
      user = Fixtures.register_user("pend-2")
      {:ok, op} = pend(user)

      assert {:ok, confirmed} =
               op |> Ash.Changeset.for_update(:confirm, %{}, actor: user) |> Ash.update()

      assert confirmed.status == :confirmed
      assert %DateTime{} = confirmed.resolved_at
    end

    test "非 pending 不可重复确认" do
      user = Fixtures.register_user("pend-3")
      {:ok, op} = pend(user)

      {:ok, confirmed} =
        op |> Ash.Changeset.for_update(:confirm, %{}, actor: user) |> Ash.update()

      assert {:error, _} =
               confirmed |> Ash.Changeset.for_update(:confirm, %{}, actor: user) |> Ash.update()
    end

    test "他人不可确认（Forbidden）" do
      owner = Fixtures.register_user("pend-4")
      other = Fixtures.register_user("pend-5")
      {:ok, op} = pend(owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               op |> Ash.Changeset.for_update(:confirm, %{}, actor: other) |> Ash.update()
    end

    test "已过期（expires_at < now）不可确认" do
      user = Fixtures.register_user("pend-6")
      {:ok, op} = pend(user)

      # 直接把 expires_at 改到过去（绕过 action，直改库）
      {:ok, expired} =
        op
        |> Ecto.Changeset.change(
          expires_at:
            DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
        )
        |> Cgc2046.Repo.update()

      assert {:error, err} =
               expired |> Ash.Changeset.for_update(:confirm, %{}, actor: user) |> Ash.update()

      assert Exception.message(err) =~ "expired"
    end
  end

  describe "cancel" do
    test "本人取消 pending → cancelled" do
      user = Fixtures.register_user("pend-7")
      {:ok, op} = pend(user)

      assert {:ok, cancelled} =
               op |> Ash.Changeset.for_update(:cancel, %{}, actor: user) |> Ash.update()

      assert cancelled.status == :cancelled
    end

    test "confirmed 不可取消" do
      user = Fixtures.register_user("pend-8")
      {:ok, op} = pend(user)

      {:ok, confirmed} =
        op |> Ash.Changeset.for_update(:confirm, %{}, actor: user) |> Ash.update()

      assert {:error, _} =
               confirmed |> Ash.Changeset.for_update(:cancel, %{}, actor: user) |> Ash.update()
    end
  end

  describe "effective_status（读时派生过期）" do
    test "pending 未过期 → pending；过期 → expired（不落库）" do
      user = Fixtures.register_user("pend-9")
      {:ok, op} = pend(user)

      loaded =
        PendingOperation
        |> Ash.get!(op.id, actor: user, load: [:effective_status])

      assert loaded.effective_status == "pending"
    end

    test "confirmed 显示 confirmed（不被过期覆盖）" do
      user = Fixtures.register_user("pend-10")
      {:ok, op} = pend(user)

      {:ok, confirmed} =
        op |> Ash.Changeset.for_update(:confirm, %{}, actor: user) |> Ash.update()

      loaded =
        PendingOperation
        |> Ash.get!(confirmed.id, actor: user, load: [:effective_status])

      assert loaded.effective_status == "confirmed"
    end
  end

  describe "read" do
    test "只能读到自己的 pending" do
      u1 = Fixtures.register_user("pend-11")
      u2 = Fixtures.register_user("pend-12")

      {:ok, _} = pend(u1)
      {:ok, _} = pend(u2)

      mine = PendingOperation |> Ash.read!(actor: u1)
      assert length(mine) == 1
      assert hd(mine).user_id == u1.id
    end
  end
end
