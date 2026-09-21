defmodule Cgc2046.Flashback.LikesTest do
  @moduledoc """
  R35-R38 金句众包 / 点赞 / 平台边界（R37 按句口径）：

  - 点赞幂等（重复点赞不重复计数、取消再赞回同一票）；
  - `voter_key` 格式与长度 fail-closed（客户端可控输入）；
  - 被赞目标必须在墙上（未授权/已下线/已撤回句都是 `flashback_quote_not_found`，
    不泄露存在性）；
  - IP 窗口 + voter_key 窗口双层限频（R29）；
  - 金句墙：likeCount / likedByViewer / **排序 = 点赞数优先、更新时间次之**；
  - R37 单句身份：一人多句各一行、独立点赞计数、单句撤回不影响同 license 其他句；
  - R38 下线开关：license 下线级联隐藏全部句，恢复后回来（policy 守卫）。
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
    Quote,
    QuoteLicense,
    Quotes,
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
    spans =
      if span,
        do: [%{question_key: "self_intro", start: span["start"], len: span["len"]}],
        else: []

    license =
      QuoteLicense
      |> Ash.Changeset.for_create(:create, %{
        person_id: person.id,
        level: level,
        chosen_quote_spans: spans
      })
      |> Ash.create!(authorize?: false)

    # R37：测试夹具直建行（绕过 Tokens.set_quote_license 的同步路径）——
    # 显式同步 Quote 行，与生产写面同终态。
    {:ok, quotes} = Quotes.sync_for_license(license)
    {license, quotes}
  end

  # 已存在授权行改档（unique_person：一人一行）
  defp promote_license(person, level) do
    license =
      QuoteLicense
      |> Ash.Query.filter(person_id == ^person.id)
      |> Ash.read_one!(authorize?: false)
      |> Ash.Changeset.for_update(:update, %{level: level})
      |> Ash.update!(authorize?: false)

    {:ok, _} = Quotes.sync_for_license(license)
    license
  end

  # 上墙者（授权 + 选定区间的最小完整形状）；返回 {person, 首句 quote}
  defp wall_person(archive, attrs \\ %{}) do
    person = create_person(archive, attrs)
    create_answer(person)
    {_license, [quote | _]} = set_license(person)
    {person, quote}
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

  defp like_count_of(quote_id) do
    Like
    |> Ash.Query.filter(quote_id == ^quote_id)
    |> Ash.count!(authorize?: false)
  end

  describe "点赞幂等与计数（R36/R37）" do
    test "重复点赞不重复计数；取消即删；取消再取消仍成功" do
      archive = create_archive()
      {_author, quote} = wall_person(archive)

      assert {:ok, %{like_count: 1}} = Likes.set_like(quote.id, "a:device-1", true, "10.0.0.1")
      assert {:ok, %{like_count: 1}} = Likes.set_like(quote.id, "a:device-1", true, "10.0.0.1")
      assert like_count_of(quote.id) == 1

      # 不同 voter_key 是不同票
      assert {:ok, %{like_count: 2}} = Likes.set_like(quote.id, "u:user-9", true, "10.0.0.2")

      assert {:ok, %{like_count: 1}} = Likes.set_like(quote.id, "a:device-1", false, "10.0.0.1")
      assert {:ok, %{like_count: 1}} = Likes.set_like(quote.id, "a:device-1", false, "10.0.0.1")
      assert {:ok, %{like_count: 2}} = Likes.set_like(quote.id, "a:device-1", true, "10.0.0.1")
    end

    test "voter_key 格式/长度 fail-closed（客户端可控输入）" do
      archive = create_archive()
      {_author, quote} = wall_person(archive)

      for bad <- ["", "x:device-1", "u:", ":device-1", "device-1", String.duplicate("a", 65)] do
        assert {:error, %{code: "flashback_invalid_voter_key"}} =
                 Likes.set_like(quote.id, bad, true, "10.1.0.1")
      end

      assert like_count_of(quote.id) == 0
    end

    test "被赞目标必须在墙上：未授权 / off 档 / 已下线 / 单句撤回 / 非法 id 都是 quote_not_found" do
      archive = create_archive()
      no_license = create_person(archive, %{email: "nol@example.com"})
      create_answer(no_license)

      off_person =
        create_person(archive, %{email: "off@example.com", full_name: "李雷", surname: "李"})

      create_answer(off_person)
      set_license(off_person, :off, nil)

      {hidden_person, hidden_quote} =
        wall_person(archive, %{email: "hid@example.com", full_name: "周迅", surname: "周"})

      admin = AccountsFixtures.platform_admin("flashback-like-admin")
      {:ok, %{hidden: true}} = QuoteLicenses.set_hidden(admin, hidden_person.id, true)

      # 单句撤回（license 未下线，仅该句 hidden_at）
      {_solo_person, solo_quote} =
        wall_person(archive, %{email: "solo@example.com", full_name: "韩梅", surname: "韩"})

      {:ok, _} =
        solo_quote
        |> Ash.Changeset.for_update(:update, %{hidden_at: DateTime.utc_now()})
        |> Ash.update(authorize?: false)

      for target <- [
            no_license.id,
            off_person.id,
            hidden_quote.id,
            solo_quote.id,
            "not-a-uuid",
            nil
          ] do
        assert {:error, %{code: "flashback_quote_not_found"}} =
                 Likes.set_like(target, "a:device-1", true, "10.2.0.1")
      end

      assert like_count_of(hidden_quote.id) == 0
      assert like_count_of(solo_quote.id) == 0
    end

    test "IP 窗口限频：超过上限 → flashback_like_rate_limited" do
      archive = create_archive()
      {_author, quote} = wall_person(archive)
      ip = "203.0.113.7"

      # 60 次窗口内（每次换 voter_key，绕开一句一票，只剩 IP 维度）
      for i <- 1..60 do
        assert {:ok, _} = Likes.set_like(quote.id, "a:rate-#{i}", true, ip)
      end

      assert {:error, %{code: "flashback_like_rate_limited"}} =
               Likes.set_like(quote.id, "a:rate-61", true, ip)
    end

    test "voter_key 窗口限频（R29）：同一 voter 每分钟 30 次上限" do
      archive = create_archive()
      {_author, quote} = wall_person(archive)

      # 同一 voter_key 反复 赞/取消（每次换 IP，绕开 IP 窗口，只剩 voter 维度）
      for i <- 1..30 do
        assert {:ok, _} =
                 Likes.set_like(
                   quote.id,
                   "a:busy-device",
                   rem(i, 2) == 1,
                   "10.9.#{div(i, 255)}.#{rem(i, 255)}"
                 )
      end

      assert {:error, %{code: "flashback_like_rate_limited"}} =
               Likes.set_like(quote.id, "a:busy-device", true, "10.9.9.9")
    end
  end

  describe "金句墙点赞面（R36/R37/R38）" do
    test "likeCount / likedByViewer / 排序 = 点赞数优先、更新时间次之" do
      archive = create_archive()
      # 三个上墙者：C 最新（0 赞）、B 中间（1 赞）、A 最旧（2 赞）
      {alice, alice_quote} =
        wall_person(archive, %{email: "a@example.com", full_name: "王晓雨", surname: "王"})

      {_bob, bob_quote} =
        wall_person(archive, %{email: "b@example.com", full_name: "李雷", surname: "李"})

      {_carol, carol_quote} =
        wall_person(archive, %{email: "c@example.com", full_name: "周迅", surname: "周"})

      {:ok, _} = Likes.set_like(alice_quote.id, "a:d1", true, "10.3.0.1")
      {:ok, _} = Likes.set_like(alice_quote.id, "a:d2", true, "10.3.0.2")
      {:ok, _} = Likes.set_like(bob_quote.id, "a:d1", true, "10.3.0.1")

      {:ok, quotes} = Public.quotes()

      # 排序：2 赞的 alice 在前（哪怕 carol 更新时间最新）
      assert Enum.map(quotes, & &1.text) |> Enum.take(3) == ["我想亲眼看", "我想亲眼看", "我想亲眼看"]
      assert Enum.map(quotes, & &1.like_count) |> Enum.take(3) == [2, 1, 0]
      assert Enum.at(quotes, 0).quote_id == alice_quote.id
      assert Enum.at(quotes, 1).quote_id == bob_quote.id
      assert Enum.at(quotes, 2).quote_id == carol_quote.id

      # likedByViewer：只有 a:d1 赞过的两条为 true
      {:ok, for_d1} = Public.quotes("a:d1")

      assert Enum.filter(for_d1, & &1.liked_by_viewer) |> Enum.map(& &1.quote_id) == [
               alice_quote.id,
               bob_quote.id
             ]

      # 不传 voter_key：恒 false
      assert Enum.all?(quotes, &(&1.liked_by_viewer == false))

      # 全字段白名单：手机/邮箱/person_id 不出现在投影里
      refute inspect(quotes) =~ "13900000001"
      refute inspect(quotes) =~ "@example.com"
      refute inspect(quotes) =~ alice.id
    end

    test "R37 一人多句：各一行、独立计数、单句撤回不影响同 license 其他句" do
      archive = create_archive()
      person = create_person(archive, %{email: "multi@example.com"})
      create_answer(person, "第一句。第二句在这里。")

      license =
        QuoteLicense
        |> Ash.Changeset.for_create(:create, %{
          person_id: person.id,
          level: :anonymous,
          chosen_quote_spans: [
            %{question_key: "self_intro", start: 0, len: 3},
            %{question_key: "self_intro", start: 4, len: 5}
          ]
        })
        |> Ash.create!(authorize?: false)

      {:ok, [first, second]} = Quotes.sync_for_license(license)

      {:ok, _} = Likes.set_like(first.id, "a:m1", true, "10.5.0.1")
      {:ok, _} = Likes.set_like(second.id, "a:m1", true, "10.5.0.1")
      {:ok, _} = Likes.set_like(second.id, "a:m2", true, "10.5.0.2")

      {:ok, quotes} = Public.quotes()
      assert length(quotes) == 2
      by_id = Map.new(quotes, &{&1.quote_id, &1})
      assert by_id[first.id].like_count == 1
      assert by_id[second.id].like_count == 2

      # 文本按各自 span 切片（grapheme 偏移；切点位置由夹具文本决定，钉长度与互异即可）
      assert by_id[first.id].text != by_id[second.id].text
      assert String.length(by_id[first.id].text) == 3
      assert String.length(by_id[second.id].text) == 5

      # 单句撤回：第二句消失，第一句不受影响
      {:ok, _} =
        second
        |> Ash.Changeset.for_update(:update, %{hidden_at: DateTime.utc_now()})
        |> Ash.update(authorize?: false)

      {:ok, quotes} = Public.quotes()
      assert Enum.map(quotes, & &1.quote_id) == [first.id]

      # 恢复（重新取行——上面的 update 已消费过 second 的 changeset 数据）
      {:ok, _} =
        Ash.get!(Quote, second.id, authorize?: false)
        |> Ash.Changeset.for_update(:update, %{hidden_at: nil})
        |> Ash.update(authorize?: false)

      {:ok, quotes} = Public.quotes()
      assert length(quotes) == 2
    end

    test "R37 编辑圈选：共有 span 原地更新保 id 与点赞；被剪 span 删行" do
      archive = create_archive()
      person = create_person(archive, %{email: "edit@example.com"})
      create_answer(person, "第一句。第二句在这里。第三句末尾。")

      license =
        QuoteLicense
        |> Ash.Changeset.for_create(:create, %{
          person_id: person.id,
          level: :anonymous,
          chosen_quote_spans: [
            %{question_key: "self_intro", start: 0, len: 3},
            %{question_key: "self_intro", start: 4, len: 5}
          ]
        })
        |> Ash.create!(authorize?: false)

      {:ok, [first, second]} = Quotes.sync_for_license(license)
      {:ok, _} = Likes.set_like(first.id, "a:e1", true, "10.6.0.1")
      {:ok, _} = Likes.set_like(second.id, "a:e1", true, "10.6.0.1")

      # 编辑：剪掉第二句、改选第三句（第一句不动）
      {:ok, license} =
        license
        |> Ash.Changeset.for_update(:update, %{
          chosen_quote_spans: [
            %{question_key: "self_intro", start: 0, len: 3},
            %{question_key: "self_intro", start: 10, len: 5}
          ]
        })
        |> Ash.update(authorize?: false)

      {:ok, quotes} = Quotes.sync_for_license(license)
      assert [kept, new] = quotes
      # 共有 span：id 稳定、点赞保留
      assert kept.id == first.id
      assert like_count_of(kept.id) == 1
      # 被剪行删除（点赞随 FK 级联）
      assert like_count_of(second.id) == 0
      assert {:error, %Ash.Error.Invalid{}} = Ash.get(Quote, second.id, authorize?: false)
      # 新句补行（span 经 Ash 类型加载为原子键 map）
      assert new.id != second.id
      assert new.span == %{start: 10, len: 5}
    end

    test "R38 下线：license 级联隐藏全部句；恢复后回来；实名档案页同步过滤" do
      admin = AccountsFixtures.platform_admin("flashback-quote-admin")
      archive = create_archive()
      {author, quote} = wall_person(archive, %{email: "credited@example.com"})
      promote_license(author, :credited)

      published =
        author
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:public_slug, "wang-xiaoyu")
        |> Ash.Changeset.force_change_attribute(:public_slug_published_at, DateTime.utc_now())
        |> Ash.update!(authorize?: false)

      assert {:ok, %{hidden: true}} = QuoteLicenses.set_hidden(admin, published.id, true)

      {:ok, quotes} = Public.quotes()
      refute Enum.any?(quotes, &(&1.quote_id == quote.id))
      assert {:ok, nil} = Public.profile("wang-xiaoyu")
      # 级联：Quote 行 hidden_at 已置位
      assert %{hidden_at: %DateTime{}} = Ash.get!(Quote, quote.id, authorize?: false)

      assert {:ok, %{hidden: false}} = QuoteLicenses.set_hidden(admin, published.id, false)
      {:ok, quotes} = Public.quotes()
      assert Enum.any?(quotes, &(&1.quote_id == quote.id))
      assert {:ok, %{quote: "我想亲眼看"}} = Public.profile("wang-xiaoyu")
      assert %{hidden_at: nil} = Ash.get!(Quote, quote.id, authorize?: false)
    end

    test "非管理员调下线被拒（policy 守卫 + 未授权行同码）" do
      plain_user = AccountsFixtures.register_user("flashback-like-plain")
      archive = create_archive()
      {author, _quote} = wall_person(archive)

      # policy 守卫：Ash 层拒绝（GraphQL 面再映射成 unauthorized 码）
      assert {:error, %Ash.Error.Forbidden{}} =
               QuoteLicenses.set_hidden(plain_user, author.id, true)

      # 未授权行（无 quote_license）→ quote_not_found（不泄露「从未授权」）
      no_license = create_person(archive, %{email: "nol2@example.com"})
      admin = AccountsFixtures.platform_admin("flashback-quote-admin-2")

      assert {:error, %{code: "flashback_quote_not_found"}} =
               QuoteLicenses.set_hidden(admin, no_license.id, true)
    end

    test "作者侧回访面：quoteStats 按人聚合其全部句（off → nil）" do
      archive = create_archive()
      {author, quote} = wall_person(archive, %{email: "stats@example.com"})
      {:ok, _} = Likes.set_like(quote.id, "a:d1", true, "10.4.0.1")
      {:ok, _} = Likes.set_like(quote.id, "a:d2", true, "10.4.0.2")

      assert %{me: %{quote_stats: %{like_count: 2}}} = capsule_for(author)

      off_person =
        create_person(archive, %{email: "off2@example.com", full_name: "李雷", surname: "李"})

      set_license(off_person, :off, nil)
      assert %{me: %{quote_stats: nil}} = capsule_for(off_person)
    end

    test "随机入口（R35）：数量正确、不含隐藏句、不含未授权者" do
      archive = create_archive()
      {_a, _q1} = wall_person(archive, %{email: "r1@example.com"})
      {_b, _q2} = wall_person(archive, %{email: "r2@example.com", full_name: "李雷", surname: "李"})

      {_c, hidden_quote} =
        wall_person(archive, %{email: "r3@example.com", full_name: "周迅", surname: "周"})

      {:ok, _} =
        hidden_quote
        |> Ash.Changeset.for_update(:update, %{hidden_at: DateTime.utc_now()})
        |> Ash.update(authorize?: false)

      # 未授权者
      silent = create_person(archive, %{email: "r4@example.com", full_name: "沈默", surname: "沈"})
      create_answer(silent)

      {:ok, random} = Public.random_quotes(10)
      assert length(random) == 2
      refute Enum.any?(random, &(&1.quote_id == hidden_quote.id))

      {:ok, one} = Public.random_quotes(1)
      assert length(one) == 1
    end

    test "单句直达（R37）：有效 id 返回该句；已撤回/不存在/非法 id 统一 nil" do
      archive = create_archive()
      {_author, quote} = wall_person(archive, %{email: "direct@example.com"})

      {_other, hidden_quote} =
        wall_person(archive, %{email: "direct2@example.com", full_name: "李雷", surname: "李"})

      {:ok, found} = Public.quote(quote.id)
      assert found.quote_id == quote.id
      assert found.text == "我想亲眼看"

      {:ok, _} =
        hidden_quote
        |> Ash.Changeset.for_update(:update, %{hidden_at: DateTime.utc_now()})
        |> Ash.update(authorize?: false)

      assert {:ok, nil} = Public.quote(hidden_quote.id)
      assert {:ok, nil} = Public.quote(Ecto.UUID.generate())
      assert {:ok, nil} = Public.quote("not-a-uuid")
      assert {:ok, nil} = Public.quote(nil)
    end
  end
end
