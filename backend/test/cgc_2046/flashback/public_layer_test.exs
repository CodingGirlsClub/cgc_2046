defmodule Cgc2046.Flashback.PublicLayerTest do
  @moduledoc """
  U6 公开层测试（R31/R32/R21/KTD3/KTD7）：

  - 统计层：聚合数字与库一致；
  - 金句墙：授权者脱敏金句 + 署名；**未授权者的内容零出现**（逐字段断言）；
  - 实名档案页：credited+已发布才可解析，未授权 nil（404 态）；
  - 找回：命中/未命中同文案（dispatched 同形）；同号超限被限流；
    多档案 verify 返回选择列表并全部绑定；防枚举（错码同文案）。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.Accounts.{PhoneVerificationCode, TokenCredential}
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Answer, Person, Public, QuoteLicense, Recover, Today, Token, Touch}
  alias Cgc2046.Repo

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

  defp create_person(archive, attrs \\ %{}) do
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

  defp create_answer(person, text \\ "我想亲眼看看是不是。", key \\ "self_intro") do
    Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: key,
      raw_text: text
    })
    |> Ash.create!(authorize?: false)
  end

  defp set_license(person, level, span, note \\ nil) do
    license =
      QuoteLicense
      |> Ash.Changeset.for_create(:create, %{
        person_id: person.id,
        level: level,
        chosen_quote_spans: [
          %{
            question_key: "self_intro",
            start: span["start"] || span[:start],
            len: span["len"] || span[:len]
          }
        ],
        credited_note: note
      })
      |> Ash.create!(authorize?: false)

    # R37：测试夹具直建行（绕过 Tokens.set_quote_license 的同步路径）——
    # 显式同步 Quote 行，与生产写面同终态。
    {:ok, _quotes} = Cgc2046.Flashback.Quotes.sync_for_license(license)
    license
  end

  # public_slug/published_at 不经 create（发布语义只在绑定通道/后续授权面）
  defp put_public_slug(person, slug) do
    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:public_slug, slug)
    |> Ash.update!(authorize?: false)
  end

  defp touch_opened(person) do
    Touch
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, event: :link_opened})
    |> Ash.create!(authorize?: false)
  end

  describe "统计层（R32）" do
    test "聚合数字与库一致；空库为零值（空态叙事的数据基础）" do
      {:ok, empty} = Public.stats()
      assert empty.archives == []
      assert empty.returned_count == 0
      assert empty.sent_count == 0

      archive = create_archive()
      alice = create_person(archive, %{email: "a@example.com"})
      bob = create_person(archive, %{email: "b@example.com", full_name: "李雷", surname: "李"})
      touch_opened(alice)
      touch_opened(bob)
      touch_opened(alice)

      Today
      |> Ash.Changeset.for_create(:create, %{person_id: alice.id})
      |> Ash.create!(authorize?: false)
      |> Ash.Changeset.for_update(:update, %{sent_to_wall_at: DateTime.utc_now()})
      |> Ash.update!(authorize?: false)

      {:ok, stats} = Public.stats()
      assert length(stats.archives) == 1
      assert hd(stats.archives).attended_count == 102
      # distinct person 计数（alice 两次 touch 只算一次）
      assert stats.returned_count == 2
      assert stats.sent_count == 1
      refute inspect(stats) =~ "13900000001"
      refute inspect(stats) =~ "@example.com"
    end
  end

  describe "金句墙（R31/R32）" do
    test "授权者脱敏金句 + 署名；未授权者的内容零出现" do
      archive = create_archive()
      alice = create_person(archive, %{email: "a@example.com"})
      silent = create_person(archive, %{email: "s@example.com", full_name: "沈默", surname: "沈"})

      create_answer(alice, "我想亲眼看看是不是。")
      # 未授权者也有答案——但绝不能出现在公开投影
      create_answer(silent, "沈默者的秘密答案。")

      set_license(alice, :anonymous, %{"start" => 0, "len" => 7})
      # off 档（默认关）即便选了区间也绝不进墙
      set_license(silent, :off, %{"start" => 0, "len" => 7})

      {:ok, quotes} = Public.quotes()
      assert length(quotes) == 1

      quote_payload = hd(quotes)
      assert quote_payload.text == "我想亲眼看看是"
      assert quote_payload.attribution == "王** · 2014 · 北京"
      assert quote_payload.level == "anonymous"
      assert is_nil(quote_payload.public_slug)

      # 未授权者的任何内容零出现（逐字段断言，KTD3）
      all = inspect(quotes)
      refute all =~ "沈默者的秘密答案"
      refute all =~ "沈**"
      refute all =~ "13900000001"
    end

    test "credited 档带 public_slug；区间切片按 grapheme" do
      archive = create_archive()
      alice = create_person(archive, %{email: "a@example.com"}) |> put_public_slug("wang-xiaoyu")
      create_answer(alice, "一个文科生，想亲眼看看是不是。")
      set_license(alice, :credited, %{"start" => 6, "len" => 8}, "在做无障碍开发")

      {:ok, quotes} = Public.quotes()
      quote_payload = hd(quotes)
      assert quote_payload.level == "credited"
      assert quote_payload.public_slug == "wang-xiaoyu"
      assert quote_payload.text == "想亲眼看看是不是"
    end
  end

  describe "实名档案页（R31 credited 档）" do
    test "已发布 public_slug + credited 才可解析；内容只含授权面" do
      archive = create_archive()

      alice = create_person(archive, %{email: "a@example.com"}) |> put_public_slug("wang-xiaoyu")

      alice
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:public_slug_published_at, DateTime.utc_now())
      |> Ash.update!(authorize?: false)

      create_answer(alice, "我想亲眼看看是不是。")
      set_license(alice, :credited, %{"start" => 0, "len" => 7}, "在做无障碍开发")

      {:ok, profile} = Public.profile("wang-xiaoyu")
      assert profile.full_name == "王晓雨"
      assert profile.city == "北京"
      assert profile.year == 2014
      assert profile.credited_note == "在做无障碍开发"
      assert profile.quote == "我想亲眼看看是"
      # 当年答案全文不进公开面（三层递进的默认）
      payload = inspect(profile)
      refute payload =~ "不是。"
      refute payload =~ "13900000001"
    end

    test "未授权者 nil（404 态）：slug 未发布 / 档 off / 不存在" do
      archive = create_archive()
      unpublished = create_person(archive, %{email: "u@example.com"}) |> put_public_slug("unpub")
      create_answer(unpublished)
      set_license(unpublished, :credited, %{"start" => 0, "len" => 2})

      published_off =
        create_person(archive, %{email: "o@example.com"}) |> put_public_slug("pub-off")

      published_off
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:public_slug_published_at, DateTime.utc_now())
      |> Ash.update!(authorize?: false)

      create_answer(published_off)
      set_license(published_off, :anonymous, %{"start" => 0, "len" => 2})

      assert {:ok, nil} = Public.profile("unpub")
      assert {:ok, nil} = Public.profile("pub-off")
      assert {:ok, nil} = Public.profile("nobody")
    end
  end

  describe "自助找回（R21/KTD7）" do
    test "命中与未命中同形返回（不泄露存在性）" do
      assert {:ok, %{dispatched: true}} = Recover.initiate("13911112222", "1.2.3.4")
      assert {:ok, %{dispatched: true}} = Recover.initiate("nobody@example.com", "1.2.3.4")
      assert {:ok, %{dispatched: true}} = Recover.initiate("不是联系方式", "1.2.3.4")
    end

    test "同 identifier 超限被限流（flashback_recover_rate_limited）" do
      for _ <- 1..5 do
        assert {:ok, _} = Recover.initiate("13933334444", "9.9.9.9")
      end

      assert {:error, %{code: "flashback_recover_rate_limited"}} =
               Recover.initiate("13933334444", "9.9.9.9")
    end

    test "多档案命中：verify 返回选择列表并全部绑定；token 全作废（R1）" do
      archive = create_archive()
      archive2 = create_archive("2015-08-gz")
      phone = "13900000001"

      p1 = create_person(archive, %{email: "a@example.com"})

      p2 =
        create_person(archive2, %{
          email: "a2@example.com",
          full_name: "李雷",
          surname: "李",
          phone: phone
        })

      plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
      {:ok, hash} = TokenCredential.hash(plain)

      Token
      |> Ash.Changeset.for_create(:create, %{person_id: p1.id, token_hash: hash})
      |> Ash.create!(authorize?: false)

      # 同生产口径：normalize → issue（U2 注记——hash 口径对齐）
      {:ok, normalized} = Cgc2046.Accounts.PhoneNumber.normalize(phone)
      {:ok, code, _} = PhoneVerificationCode.issue(normalized, :register)

      assert {:ok, %{bound: true, cards: cards}} = Recover.verify(phone, code, %{})

      # 多档案命中返回选择列表（你的 N 张卡）
      assert length(cards) == 2
      assert Enum.map(cards, & &1.surname_masked) |> Enum.sort() == ["李*", "王**"]
      refute inspect(cards) =~ "13900000001"
      refute inspect(cards) =~ "@example.com"

      # 全部绑定 + 旧 token 作废（R1 账号接管）
      for person <- [p1, p2] do
        reloaded =
          Person
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(id == ^person.id)
          |> Ash.read_one!(authorize?: false)

        assert not is_nil(reloaded.user_id)
      end

      claimed =
        Token
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(person_id == ^p1.id)
        |> Ash.read_one!(authorize?: false)

      assert not is_nil(claimed.claimed_by_user_id)
    end

    test "错码与不存在同文案（invalid_or_expired_code）" do
      assert {:error, %{code: "invalid_or_expired_code"}} =
               Recover.verify("13900000001", "000000", %{})

      assert {:error, %{code: "invalid_or_expired_code"}} =
               Recover.verify("nobody@example.com", "000000", %{})
    end
  end
end
