defmodule Cgc2046.Flashback.WishAccountAuthorTest do
  use Cgc2046.DataCase, async: false
  alias Cgc2046.Flashback.{Wish, WishAuthors, WishWriting, Wishes, Reports}
  alias Cgc2046.AccountsFixtures
  alias Cgc2046.MiniprogramFixtures.Barrier
  @moduletag :capture_log

  test "account-only public readers and private admin inbox tolerate absent archive; moderation credit targets account" do
    user = AccountsFixtures.register_user("account-readers")

    {:ok, public} =
      WishWriting.create({:user, user.id}, "一起创造", "public",
        expected_city: "成都",
        public_listing_consent: true
      )

    {:ok, private} = WishWriting.create({:user, user.id}, "给主办方", "private", expected_city: "成都")

    # P2-1 机审通道门：account-only 作者无微信身份 → 公开愿待审（公开面可见但不挂树）
    assert [%{id: public_id, wisher_masked: "匿名"}] = Wishes.list_public()
    assert public_id == public.id
    refute Enum.any?(Wishes.list_public_listed(), &(&1.id == public.id))

    assert [%{wish: %{id: private_id}, wisher_user_contact: %{email: email}}] =
             Reports.list_inbox_private_wishes()

    assert private_id == private.id
    assert email == to_string(user.email)
    assert :noop = Reports.set_author_credit_required(public, DateTime.utc_now())

    assert %{rows: [[stamp]]} =
             Repo.query!("SELECT wishes_review_required_at FROM users WHERE id=$1", [
               Repo.uuid!(user.id)
             ])

    assert stamp
    assert {:error, %{code: "flashback_forbidden_wish"}} = Wishes.soft_delete_wish(public.id, nil)
  end

  test "account-only body is moderated, including private content" do
    user = AccountsFixtures.register_user("account-moderated")

    Cgc2046.Accounts.UserIdentity
    |> Ash.Changeset.for_create(:upsert, %{
      provider: :wechat,
      uid: "synthetic-wish2a-openid",
      user_id: user.id
    })
    |> Ash.create!(authorize?: false)

    Tesla.Mock.mock(fn %{method: :post, url: "https://api.weixin.qq.com/wxa/msg_sec_check" <> _} ->
      send(self(), :body_checked)
      Tesla.Mock.json(%{"errcode" => 0, "result" => %{"suggest" => "risky", "label" => 20002}})
    end)

    assert {:error, %{code: "flashback_content_rejected"}} =
             WishWriting.create({:user, user.id}, "合成拦截文本", "private", expected_city: "成都")

    assert_receive :body_checked
    assert {:ok, %{quota_remaining: 3, wishes: []}} = WishAuthors.mine(user.id)
  end

  test "replay still works after quota exhaustion and deletion, without recreating a row" do
    user = AccountsFixtures.register_user("account-replay")
    opts = [expected_city: "成都", request_id: "stable-attempt"]
    assert {:ok, first} = WishWriting.create({:user, user.id}, "重试", "public", opts)

    for i <- 1..2,
        do:
          assert(
            {:ok, _} =
              WishWriting.create({:user, user.id}, "填满额度#{i}", "private", expected_city: "成都")
          )

    assert {:ok, _} = Wishes.soft_delete_wish(first.id, {:user, user.id})
    assert {:ok, replay} = WishWriting.create({:user, user.id}, "重试", "public", opts)
    assert replay.id == first.id
    assert replay.deleted_at
    assert WishAuthors.quota_remaining({:user, user.id}) == 0
    assert Repo.aggregate(Wish, :count) == 3
  end

  test "10 concurrent account writers consume at most 3 annual slots" do
    barrier = start_supervised!({Barrier, 10})

    user =
      unboxed(fn ->
        AccountsFixtures.register_user("account-race-#{System.unique_integer([:positive])}")
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.query!("DELETE FROM flashback_wishes WHERE user_id=$1", [Repo.uuid!(user.id)])
        Repo.query!("DELETE FROM users WHERE id=$1", [Repo.uuid!(user.id)])
      end)
    end)

    results =
      Enum.map(1..10, fn i ->
        Task.async(fn ->
          Barrier.arrive(barrier)

          unboxed(fn ->
            WishWriting.create({:user, user.id}, "并发 #{i}", "public", expected_city: "成都")
          end)
        end)
      end)
      |> Task.await_many(15_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 3

    assert Enum.count(results, &match?({:error, %{code: "flashback_wish_quota_exceeded"}}, &1)) ==
             7

    assert unboxed(fn -> WishAuthors.quota_remaining({:user, user.id}) end) == 0
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
