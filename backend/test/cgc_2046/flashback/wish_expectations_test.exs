defmodule Cgc2046.Flashback.WishExpectationsTest do
  @moduledoc """
  U2 KTD2:`期待` 动作的 voter 解析、去重、限频、登录合并、
  目标可见性（KTD9）、双指标分离。
  """
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Flashback.WishExpectations
  alias Cgc2046.Flashback.Wishes

  defp create_archive do
    Cgc2046.Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-bj-w#{System.unique_integer([:positive])}",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, overrides \\ %{}) do
    Cgc2046.Flashback.Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: archive.id,
          full_name: "王小明",
          surname: "王",
          city: "北京",
          participation: :attended
        },
        overrides
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp register_user(prefix) do
    Cgc2046.AccountsFixtures.register_user("#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp bind_person_to_user(person_id, user_id) do
    {1, _} =
      Repo.query(
        "UPDATE flashback_people SET user_id = $1 WHERE id = $2",
        [Repo.uuid!(user_id), Repo.uuid!(person_id)]
      )
      |> case do
        {:ok, %{num_rows: n} = res} -> {n, res}
        other -> raise "update failed: #{inspect(other)}"
      end

    :ok
  end

  # listed public not hidden not deleted → 公开树可见
  defp create_listed_wish(person, content) do
    {:ok, wish} =
      Wishes.create_wish(person.id, content, "public",
        public_listing_consent: true,
        signature_choice: :anonymous
      )

    wish
  end

  # 未 listed public → 仅成员面
  defp create_member_wish(person, content) do
    {:ok, wish} =
      Wishes.create_wish(person.id, content, "public", public_listing_consent: false)

    wish
  end

  describe "voter_key 解析（登录强制 u:）" do
    test "纯匿名（nil actor_user_id + a: 键）成功" do
      archive = create_archive()
      person = create_person(archive)
      wish = create_listed_wish(person, "说给所有人听")

      assert {:ok, %{expectation_count: 1, expected_by_me: true}} =
               WishExpectations.set_expectation(wish.id, true,
                 anon_voter_key: "a:dev-#{System.unique_integer([:positive])}"
               )
    end

    test "登录 actor（actor_user_id 非空）→ 强制 u:<uid>，丢弃入参 anon 键" do
      archive = create_archive()
      person = create_person(archive)
      user = register_user("u2")
      :ok = bind_person_to_user(person.id, user.id)
      wish = create_listed_wish(person, "登录期待")

      assert {:ok, %{expectation_count: 1, expected_by_me: true}} =
               WishExpectations.set_expectation(wish.id, true,
                 actor_user_id: user.id,
                 anon_voter_key: "a:should-be-ignored"
               )
    end

    test "登录 + nil anon → 完整 u: 键" do
      archive = create_archive()
      person = create_person(archive)
      user = register_user("u2")
      :ok = bind_person_to_user(person.id, user.id)
      wish = create_listed_wish(person, "再看一次")

      assert {:ok, %{expectation_count: 1, expected_by_me: true}} =
               WishExpectations.set_expectation(wish.id, true, actor_user_id: user.id)
    end

    test "完全没有 voter 信息 → flashback_invalid_voter_key" do
      archive = create_archive()
      person = create_person(archive)
      wish = create_listed_wish(person, "无 voter 期待")

      assert {:error, %{code: "flashback_invalid_voter_key"}} =
               WishExpectations.set_expectation(wish.id, true)
    end

    test "voter_key 超 64 字 → flashback_invalid_voter_key" do
      archive = create_archive()
      person = create_person(archive)
      wish = create_listed_wish(person, "超长键")

      assert {:error, %{code: "flashback_invalid_voter_key"}} =
               WishExpectations.set_expectation(wish.id, true,
                 anon_voter_key: "a:" <> String.duplicate("x", 80)
               )
    end
  end

  describe "幂等与去重（KTD2）" do
    test "双次 expect 同一 voter → 只算一票" do
      archive = create_archive()
      person = create_person(archive)
      wish = create_listed_wish(person, "别多算我")
      key = "a:dev-#{System.unique_integer([:positive])}"

      assert {:ok, %{expectation_count: 1}} =
               WishExpectations.set_expectation(wish.id, true, anon_voter_key: key)

      assert {:ok, %{expectation_count: 1}} =
               WishExpectations.set_expectation(wish.id, true, anon_voter_key: key)

      assert WishExpectations.count_for_wish(wish.id) == 1
    end

    test "不同 voter 分别 expect → 计数累加" do
      archive = create_archive()
      person = create_person(archive)
      wish = create_listed_wish(person, "三个人的期待")

      for i <- 1..3 do
        {:ok, _} =
          WishExpectations.set_expectation(wish.id, true,
            anon_voter_key: "a:dev-#{i}-#{System.unique_integer([:positive])}"
          )
      end

      assert WishExpectations.count_for_wish(wish.id) == 3
    end

    test "unexpect 删行；再 unexpect 也无副作用" do
      archive = create_archive()
      person = create_person(archive)
      wish = create_listed_wish(person, "走了")
      key = "a:dev-#{System.unique_integer([:positive])}"

      {:ok, %{expectation_count: 1}} =
        WishExpectations.set_expectation(wish.id, true, anon_voter_key: key)

      assert {:ok, %{expectation_count: 0, expected_by_me: false}} =
               WishExpectations.set_expectation(wish.id, false, anon_voter_key: key)

      # 再次 unexpect 也成功
      assert {:ok, %{expectation_count: 0, expected_by_me: false}} =
               WishExpectations.set_expectation(wish.id, false, anon_voter_key: key)
    end
  end

  describe "目标可见性（KTD9）" do
    test "公开面对未 listed 愿望 → flashback_wish_not_found" do
      archive = create_archive()
      person = create_person(archive)
      wish = create_member_wish(person, "成员可见小秘密")

      assert {:error, %{code: "flashback_wish_not_found"}} =
               WishExpectations.set_expectation(wish.id, true,
                 anon_voter_key: "a:dev-#{System.unique_integer([:positive])}"
               )
    end

    test "登录成员面对未 listed 愿望可期待" do
      archive = create_archive()
      person = create_person(archive)
      user = register_user("u2")
      :ok = bind_person_to_user(person.id, user.id)
      wish = create_member_wish(person, "未 listed 但成员可见")

      assert {:ok, %{expectation_count: 1}} =
               WishExpectations.set_expectation(wish.id, true,
                 actor_user_id: user.id,
                 anon_voter_key: "a:dev-#{System.unique_integer([:positive])}"
               )
    end

    test "viewer（登录无 person）对未 listed 愿望 → flashback_wish_not_found（FIX-2 KTD9）" do
      archive = create_archive()
      owner = create_person(archive)
      {:ok, member_only} =
        Wishes.create_wish(owner.id, "成员面期待愿", "public", public_listing_consent: false)

      viewer = register_user("u2-viewer")
      # viewer 未绑定任何 person

      assert {:error, %{code: "flashback_wish_not_found"}} =
               WishExpectations.set_expectation(member_only.id, true, actor_user_id: viewer.id)
    end

    test "对 hidden 愿望 → flashback_wish_not_found" do
      archive = create_archive()
      person = create_person(archive)
      wish = create_listed_wish(person, "将被下架")

      Repo.query!(
        "UPDATE flashback_wishes SET hidden_at = now() WHERE id = $1",
        [Repo.uuid!(wish.id)]
      )

      assert {:error, %{code: "flashback_wish_not_found"}} =
               WishExpectations.set_expectation(wish.id, true,
                 anon_voter_key: "a:dev-#{System.unique_integer([:positive])}"
               )
    end
  end

  describe "登录 expect 合并匿名（KTD2）" do
    test "登录 expect 带 anonVoterKey → 服务端删 anon 行 + 插 u: 行" do
      archive = create_archive()
      person = create_person(archive)
      user = register_user("u2")
      :ok = bind_person_to_user(person.id, user.id)
      wish = create_listed_wish(person, "同人跨设备")

      anon_key = "a:dev-#{System.unique_integer([:positive])}"

      {:ok, %{expectation_count: 1}} =
        WishExpectations.set_expectation(wish.id, true, anon_voter_key: anon_key)

      # 同人登录后带 anonVoterKey → 合并
      {:ok, %{expectation_count: 1}} =
        WishExpectations.set_expectation(wish.id, true,
          actor_user_id: user.id,
          anon_voter_key: anon_key
        )

      assert WishExpectations.count_for_wish(wish.id) == 1

      ids = WishExpectations.expected_wish_ids([wish.id], user.id, anon_key)
      assert MapSet.member?(ids, wish.id)
    end

    test "同人登录后未带 anonVoterKey → 出现两行（KTD2 用户拍板：「分开统计没关系」）" do
      archive = create_archive()
      person = create_person(archive)
      user = register_user("u2")
      :ok = bind_person_to_user(person.id, user.id)
      wish = create_listed_wish(person, "合并失败场景")

      anon_key = "a:dev-#{System.unique_integer([:positive])}"

      {:ok, %{expectation_count: 1}} =
        WishExpectations.set_expectation(wish.id, true, anon_voter_key: anon_key)

      {:ok, %{expectation_count: 2}} =
        WishExpectations.set_expectation(wish.id, true, actor_user_id: user.id)

      assert WishExpectations.count_for_wish(wish.id) == 2
    end
  end

  describe "限频（R29 双窗）" do
    test "voter_key 30 次/分钟窗口" do
      archive = create_archive()
      person = create_person(archive)
      wish = create_listed_wish(person, "期待再期待")
      key = "a:dev-#{System.unique_integer([:positive])}"

      # 30 次调用全部成功（同 voter upsert 不重复计数，但消耗限频 budget）
      for _ <- 1..30 do
        {:ok, _} = WishExpectations.set_expectation(wish.id, true, anon_voter_key: key)
      end

      # 第 31 次被限频拦截
      assert {:error, %{code: "flashback_expectation_rate_limited"}} =
               WishExpectations.set_expectation(wish.id, false, anon_voter_key: key)
    end
  end

  describe "双指标分离" do
    test "expect 不动 endorsement_count；endorse 不动 expectation_count" do
      archive = create_archive()
      person = create_person(archive)
      user = register_user("u2")
      :ok = bind_person_to_user(person.id, user.id)
      wish = create_listed_wish(person, "两个计数分开")

      {:ok, %{expectation_count: 1}} =
        WishExpectations.set_expectation(wish.id, true, actor_user_id: user.id)

      {:ok, %{endorsement_count: 1}} = Wishes.endorse(person.id, wish.id)

      assert WishExpectations.count_for_wish(wish.id) == 1
    end
  end
end
