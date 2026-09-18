defmodule Cgc2046.Flashback.LikesTest do
  @moduledoc """
  R35-R38 金句众包 / 点赞 / 平台边界：

  - 点赞幂等（重复点赞不重复计数、取消再赞回同一票）；
  - `voter_key` 格式与长度 fail-closed（客户端可控输入）；
  - 被赞目标必须在墙上（未授权/已下线都是 `flashback_quote_not_found`，不泄露存在性）；
  - IP 窗口限频；
  - 金句墙：likeCount / likedByViewer / **排序 = 点赞数优先、更新时间次之**；
  - R38 下线开关：quotes 与实名档案页同时过滤，非管理员被拒（policy 守卫）。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures
  alias Cgc2046.Flashback

  alias Cgc2046.Flashback.{
    AlumniProjection,
    Answer,
    Like,
    Likes,
    Person,
    Public,
    QuoteLicense,
    Token
  }

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.Flashback.QuoteLicenses

  defp create_archive(key \\ "2014-01-11-bj") do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: key,
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11],
      applied_count: 344,
      attended_count: 102
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, attrs) do
    Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: archive.id,
          full_name: "王晓雨",
          surname: "王",
          city: "北京",
          occupation_then: "学生",
          role: :learner,
          participation: :attended,
          phone: "13900000001",
          email: "person@example.com"
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_answer(person, text \\ "我想亲眼看看是不是。") do
    Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: "self_intro",
      raw_text: text
    })
    |> Ash.create!(authorize?: false)
  end

  defp set_license(person, level \\ :anonymous, span \\ %{"start" => 0, "len" => 5}) do
    QuoteLicense
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      level: level,
      question_key: "self_intro",
      chosen_quote_span: span
    })
    |> Ash.create!(authorize?: false)
  end

  # 已存在授权行改档（unique_person：一人一行）
  defp promote_license(person, level) do
    QuoteLicense
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.read_one!(authorize?: false)
    |> Ash.Changeset.for_update(:update, %{level: level})
    |> Ash.update!(authorize?: false)
  end

  # 上墙者（授权 + 选定区间的最小完整形状）
  defp wall_person(archive, attrs \\ %{}) do
    person = create_person(archive, attrs)
    create_answer(person)
    set_license(person)
    person
  end

  # 真回访链路：铸 token → resolve_person → capsule（quoteStats 的消费面）
  defp capsule_for(person) do
    plain = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    {:ok, resolved} = AlumniProjection.resolve_person(plain, nil)
    {:ok, capsule} = AlumniProjection.capsule(resolved)
    capsule
  end

  defp like_count_of(person_id) do
    Like
    |> Ash.Query.filter(person_id == ^person_id)
    |> Ash.count!(authorize?: false)
  end

  describe "点赞幂等与计数（R36）" do
    test "重复点赞不重复计数；取消即删；取消再取消仍成功" do
      archive = create_archive()
      author = wall_person(archive)

      assert {:ok, %{like_count: 1}} = Likes.set_like(author.id, "a:device-1", true, "10.0.0.1")
      assert {:ok, %{like_count: 1}} = Likes.set_like(author.id, "a:device-1", true, "10.0.0.1")
      assert like_count_of(author.id) == 1

      # 不同 voter_key 是不同票
      assert {:ok, %{like_count: 2}} = Likes.set_like(author.id, "u:user-9", true, "10.0.0.2")

      assert {:ok, %{like_count: 1}} = Likes.set_like(author.id, "a:device-1", false, "10.0.0.1")
      assert {:ok, %{like_count: 1}} = Likes.set_like(author.id, "a:device-1", false, "10.0.0.1")
      assert {:ok, %{like_count: 2}} = Likes.set_like(author.id, "a:device-1", true, "10.0.0.1")
    end

    test "voter_key 格式/长度 fail-closed（客户端可控输入）" do
      archive = create_archive()
      author = wall_person(archive)

      for bad <- ["", "x:device-1", "u:", ":device-1", "device-1", String.duplicate("a", 65)] do
        assert {:error, %{code: "flashback_invalid_voter_key"}} =
                 Likes.set_like(author.id, bad, true, "10.1.0.1")
      end

      assert like_count_of(author.id) == 0
    end

    test "被赞目标必须在墙上：未授权 / off 档 / 已下线 / 非法 id 都是 quote_not_found" do
      archive = create_archive()
      no_license = create_person(archive, %{email: "nol@example.com"})
      create_answer(no_license)

      off_person =
        create_person(archive, %{email: "off@example.com", full_name: "李雷", surname: "李"})

      create_answer(off_person)
      set_license(off_person, :off, nil)

      hidden_person =
        wall_person(archive, %{email: "hid@example.com", full_name: "周迅", surname: "周"})

      admin = AccountsFixtures.platform_admin("flashback-like-admin")
      {:ok, %{hidden: true}} = QuoteLicenses.set_hidden(admin, hidden_person.id, true)

      for target <- [no_license.id, off_person.id, hidden_person.id, "not-a-uuid", nil] do
        assert {:error, %{code: "flashback_quote_not_found"}} =
                 Likes.set_like(target, "a:device-1", true, "10.2.0.1")
      end

      assert like_count_of(hidden_person.id) == 0
    end

    test "IP 窗口限频：超过上限 → flashback_like_rate_limited" do
      archive = create_archive()
      author = wall_person(archive)
      ip = "203.0.113.7"

      # 60 次窗口内（每次换 voter_key，绕开一人一票，只剩 IP 维度）
      for i <- 1..60 do
        assert {:ok, _} = Likes.set_like(author.id, "a:rate-#{i}", true, ip)
      end

      assert {:error, %{code: "flashback_like_rate_limited"}} =
               Likes.set_like(author.id, "a:rate-61", true, ip)
    end
  end

  describe "金句墙点赞面（R36/R38）" do
    test "likeCount / likedByViewer / 排序 = 点赞数优先、更新时间次之" do
      archive = create_archive()
      # 三个上墙者：C 最新（0 赞）、B 中间（1 赞）、A 最旧（2 赞）
      alice = wall_person(archive, %{email: "a@example.com", full_name: "王晓雨", surname: "王"})
      bob = wall_person(archive, %{email: "b@example.com", full_name: "李雷", surname: "李"})
      carol = wall_person(archive, %{email: "c@example.com", full_name: "周迅", surname: "周"})

      {:ok, _} = Likes.set_like(alice.id, "a:d1", true, "10.3.0.1")
      {:ok, _} = Likes.set_like(alice.id, "a:d2", true, "10.3.0.2")
      {:ok, _} = Likes.set_like(bob.id, "a:d1", true, "10.3.0.1")

      {:ok, quotes} = Public.quotes()

      # 排序：2 赞的 alice 在前（哪怕 carol 更新时间最新）
      assert Enum.map(quotes, & &1.text) |> Enum.take(3) == ["我想亲眼看", "我想亲眼看", "我想亲眼看"]
      assert Enum.map(quotes, & &1.like_count) |> Enum.take(3) == [2, 1, 0]
      assert Enum.at(quotes, 0).person_id == alice.id
      assert Enum.at(quotes, 1).person_id == bob.id
      assert Enum.at(quotes, 2).person_id == carol.id

      # likedByViewer：只有 a:d1 赞过的两条为 true
      {:ok, for_d1} = Public.quotes("a:d1")

      assert Enum.filter(for_d1, & &1.liked_by_viewer) |> Enum.map(& &1.person_id) == [
               alice.id,
               bob.id
             ]

      # 不传 voter_key：恒 false
      assert Enum.all?(quotes, &(&1.liked_by_viewer == false))

      # 全字段白名单：手机/邮箱不出现在投影里
      refute inspect(quotes) =~ "13900000001"
      refute inspect(quotes) =~ "@example.com"
    end

    test "R38 下线：quotes 与实名档案页同时过滤；恢复后回来" do
      admin = AccountsFixtures.platform_admin("flashback-quote-admin")
      archive = create_archive()
      author = wall_person(archive, %{email: "credited@example.com"})
      promote_license(author, :credited)

      published =
        author
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:public_slug, "wang-xiaoyu")
        |> Ash.Changeset.force_change_attribute(:public_slug_published_at, DateTime.utc_now())
        |> Ash.update!(authorize?: false)

      assert {:ok, %{hidden: true}} = QuoteLicenses.set_hidden(admin, published.id, true)

      {:ok, quotes} = Public.quotes()
      refute Enum.any?(quotes, &(&1.person_id == published.id))
      assert {:ok, nil} = Public.profile("wang-xiaoyu")

      assert {:ok, %{hidden: false}} = QuoteLicenses.set_hidden(admin, published.id, false)
      {:ok, quotes} = Public.quotes()
      assert Enum.any?(quotes, &(&1.person_id == published.id))
      assert {:ok, %{quote: "我想亲眼看"}} = Public.profile("wang-xiaoyu")
    end

    test "非管理员调下线被拒（policy 守卫 + 未授权行同码）" do
      plain_user = AccountsFixtures.register_user("flashback-like-plain")
      archive = create_archive()
      author = wall_person(archive)

      # policy 守卫：Ash 层拒绝（GraphQL 面再映射成 unauthorized 码）
      assert {:error, %Ash.Error.Forbidden{}} =
               QuoteLicenses.set_hidden(plain_user, author.id, true)

      # 未授权行（无 quote_license）→ quote_not_found（不泄露「从未授权」）
      no_license = create_person(archive, %{email: "nol2@example.com"})
      admin = AccountsFixtures.platform_admin("flashback-quote-admin-2")

      assert {:error, %{code: "flashback_quote_not_found"}} =
               QuoteLicenses.set_hidden(admin, no_license.id, true)
    end

    test "作者侧回访面：quoteStats 仅授权档返回（off → nil）" do
      archive = create_archive()
      author = wall_person(archive, %{email: "stats@example.com"})
      {:ok, _} = Likes.set_like(author.id, "a:d1", true, "10.4.0.1")
      {:ok, _} = Likes.set_like(author.id, "a:d2", true, "10.4.0.2")

      assert %{me: %{quote_stats: %{like_count: 2}}} = capsule_for(author)

      off_person =
        create_person(archive, %{email: "off2@example.com", full_name: "李雷", surname: "李"})

      set_license(off_person, :off, nil)
      assert %{me: %{quote_stats: nil}} = capsule_for(off_person)
    end
  end
end
