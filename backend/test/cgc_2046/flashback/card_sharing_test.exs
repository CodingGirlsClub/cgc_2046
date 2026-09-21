defmodule Cgc2046.Flashback.CardSharingTest do
  @moduledoc """
  #771 卡片分享链接——开关生命周期、隐私回归、删除撤链。

  隐私铁律（本文件逐条钉住）：

  - 分享与**金句授权档 / 公开 slug / 已寄出状态全部无依赖**；
  - 投影白名单：只出隐名 + 城市 + 报名时间 + 当年三题（self_intro /
    funny_thing / os）+ 今天四格（today.now / want / need / say）；
  - 雾面段 `text` 恒空串（原文字符不出响应体），`fog_spans` 坐标不进投影；
  - 手机 / 邮箱 / 性别 / 职业 / public_slug 零出现；
  - 标识铸出即不可变（关闭不清、重开同号）；
  - 删除（U10）即刻撤链。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Answer, CardSharing, Deletion, Person, SharedCard, Today, Token}
  alias Cgc2046.Repo

  @moduletag :capture_log

  defp create_archive do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-bj-#{System.unique_integer([:positive])}",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          full_name: "王小明",
          surname: "王",
          city: "北京",
          occupation_then: "学生",
          gender: "女",
          role: :learner,
          participation: :attended,
          phone: "13900000001",
          email: "card-share@example.com"
        },
        attrs
      )

    Person
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :archive_event_id, archive.id))
    |> Ash.create!(authorize?: false)
  end

  defp create_answer(person, key, text, fog_spans \\ []) do
    Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: key,
      raw_text: text,
      fog_spans: fog_spans
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_today(person, attrs) do
    Today
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :person_id, person.id))
    |> Ash.create!(authorize?: false)
  end

  defp issue_token(person) do
    plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end

  defp reload_person(id), do: Repo.reload!(%Person{id: id})

  defp share_id(person), do: reload_person(person.id).card_share_slug

  describe "开关生命周期（标识不可变）" do
    test "首开铸 48 字符 hex；关闭只清开关；重开复用同号" do
      person = create_person(create_archive())

      assert {:ok, %{enabled: true, share_id: first_id}} =
               CardSharing.set(true, {:person, person.id})

      assert first_id =~ ~r/^[0-9a-f]{48}$/
      assert reload_person(person.id).card_share_enabled_at != nil
      assert SharedCard.get(first_id) != nil

      # 关闭：链接即刻失效，标识保留（已投出的链接不因开关换号）
      assert {:ok, %{enabled: false, share_id: ^first_id}} =
               CardSharing.set(false, {:person, person.id})

      assert reload_person(person.id).card_share_enabled_at == nil
      assert reload_person(person.id).card_share_slug == first_id
      assert SharedCard.get(first_id) == nil

      # 重开：同一标识复活
      assert {:ok, %{enabled: true, share_id: ^first_id}} =
               CardSharing.set(true, {:person, person.id})

      assert SharedCard.get(first_id) != nil
    end

    test "重复开启幂等：标识不重铸" do
      person = create_person(create_archive())

      assert {:ok, %{share_id: first_id}} = CardSharing.set(true, {:person, person.id})
      assert {:ok, %{share_id: ^first_id}} = CardSharing.set(true, {:person, person.id})
    end

    test "客户端无法直写标识与开关：accept 白名单外的属性被拒" do
      person = create_person(create_archive())

      # 内部 update 面只接受 public_slug；分享两列不在 accept（服务端铸号唯一入口）
      assert {:error, %Ash.Error.Invalid{}} =
               person
               |> Ash.Changeset.for_update(:update, %{card_share_slug: "attacker-chosen"})
               |> Ash.update(authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               person
               |> Ash.Changeset.for_update(:update, %{card_share_enabled_at: DateTime.utc_now()})
               |> Ash.update(authorize?: false)

      assert reload_person(person.id).card_share_slug == nil
      assert reload_person(person.id).card_share_enabled_at == nil
    end

    test "状态读取：未开启 → enabled false / share_id null / 预览仍可用" do
      person = create_person(create_archive())
      create_answer(person, "self_intro", "我在盛大做测试。")

      state = CardSharing.state(person.id)
      assert state.enabled == false
      assert state.share_id == nil
      assert state.preview.display_name == "王**"
      assert Enum.map(state.preview.answers, & &1.question_key) == ["self_intro"]
    end
  end

  describe "身份（token / 绑定账号，绝不信任客户端 person id）" do
    test "token 入口解析本人档案" do
      person = create_person(create_archive())
      token = issue_token(person)

      assert {:ok, %{enabled: true, share_id: share_id}} = CardSharing.set(true, {:token, token})
      assert share_id == share_id(person)
    end

    test "失效 token → 原样透传 token 面错误码" do
      assert {:error, %{code: "flashback_token_not_found"}} =
               CardSharing.set(true, {:token, "fb_not-a-real-token"})
    end

    test "档案不存在 / 已删除 → flashback_person_not_found（拒绝开启）" do
      assert {:error, %{code: "flashback_person_not_found"}} =
               CardSharing.set(true, {:person, Ecto.UUID.generate()})

      person = create_person(create_archive())
      assert {:ok, %{share_id: share_id}} = CardSharing.set(true, {:person, person.id})

      assert {:ok, %{deleted: true}} = Deletion.delete(%{person: person}, "DELETE")

      assert {:error, %{code: "flashback_person_not_found"}} =
               CardSharing.set(true, {:person, person.id})

      # 已删除档案的链接不可解析（双保险：deleted_at 与两列清空）
      assert SharedCard.get(share_id) == nil
    end

    test "缺身份 → flashback_auth_required" do
      assert {:error, %{code: "flashback_auth_required"}} = CardSharing.set(true, nil)
    end
  end

  describe "投影白名单（隐私回归）" do
    setup do
      archive = create_archive()
      person = create_person(archive)

      create_answer(person, "self_intro", "我在盛大做测试。喜欢周末骑行。", [
        %{"start" => 0, "len" => 6}
      ])

      create_answer(person, "funny_thing", "把生产库当测试库。")
      create_answer(person, "os", "Ubuntu 14.04")
      # 不在白名单：社交媒体系一律不出对外投影
      create_answer(person, "social_media", "weibo.com/wangxiaoming")

      create_today(person, %{
        now_status: "还在写代码",
        want: "想系统学 AI",
        need: "想找一位导师",
        say: "十周年快乐！",
        fog_spans: %{"want" => [%{"start" => 0, "len" => 2}]}
      })

      assert {:ok, %{share_id: share_id}} = CardSharing.set(true, {:person, person.id})

      %{person: person, share_id: share_id, card: SharedCard.get(share_id)}
    end

    test "字段白名单：隐名/城市/报名时间/活动日/answers/today", %{card: card} do
      assert Map.keys(card) |> Enum.sort() ==
               [:answers, :applied_at, :city, :display_name, :occurred_on, :today]

      assert card.display_name == "王**"
      assert card.city == "北京"
      assert card.occurred_on == "2014-01-11"
    end

    test "当年答案只出三键（self_intro / funny_thing / os），social_media 零出现", %{card: card} do
      assert Enum.map(card.answers, & &1.question_key) == ["self_intro", "funny_thing", "os"]
      refute inspect(card) =~ "social_media"
      refute inspect(card) =~ "weibo.com"
    end

    test "今天四格全出（含 need），键名为 today.now/want/need/say", %{card: card} do
      assert Enum.map(card.today, & &1.question_key) == [
               "today.now",
               "today.want",
               "today.need",
               "today.say"
             ]
    end

    test "雾面段 text 恒空串：原文零泄露，段序为原文顺序", %{card: card} do
      [intro] = Enum.filter(card.answers, &(&1.question_key == "self_intro"))

      # 段序还原：明文「。喜欢周末骑行。」在后（segments 内部构造为逆序，投影已 reverse）
      fog = Enum.find(intro.segments, & &1.fog)
      assert fog.text == ""
      assert fog.len == 6

      plain_segments = Enum.reject(intro.segments, & &1.fog)
      assert Enum.map(plain_segments, & &1.text) == ["试。喜欢周末骑行。"]
      assert Enum.find_index(intro.segments, & &1.fog) == 0

      # 原文字符（雾面覆盖的那 6 个字）不出现在任何段文本里
      refute inspect(intro.segments) =~ "我在盛大"
      refute inspect(card) =~ "我在盛大"
    end

    test "今天雾面同规则：雾段空串，明文段原样", %{card: card} do
      want = Enum.find(card.today, &(&1.question_key == "today.want"))
      assert [%{text: "", fog: true, len: 2}, %{text: "统学 AI", fog: false}] = want.segments
    end

    test "段形状与节形状键集冻结（无 fog_spans / start / reason 等坐标泄露）", %{card: card} do
      section = hd(card.answers)
      assert Map.keys(section) |> Enum.sort() == [:question_key, :segments]

      segment = hd(section.segments)
      assert Map.keys(segment) |> Enum.sort() == [:fog, :len, :text]
      refute inspect(card) =~ "\"start\""
      refute inspect(card) =~ "reason"
    end

    test "敏感列零出现（手机 / 邮箱 / 性别 / 职业 / public_slug）", %{card: card} do
      payload = inspect(card)
      refute payload =~ "13900000001"
      refute payload =~ "card-share@example.com"
      refute payload =~ "学生"
      refute payload =~ "public_slug"
    end

    test "全雾句算内容（不剔除）" do
      person = create_person(create_archive())

      create_answer(person, "self_intro", "我在盛大做测试。", [%{"start" => 0, "len" => 8}])

      assert {:ok, %{share_id: share_id}} = CardSharing.set(true, {:person, person.id})
      card = SharedCard.get(share_id)

      assert Enum.map(card.answers, & &1.question_key) == ["self_intro"]
      [segment] = hd(card.answers).segments
      assert segment.fog == true and segment.text == "" and segment.len == 8
    end
  end

  describe "与授权档 / 寄出状态无依赖（独立成立）" do
    test "无金句授权、未寄出 → 分享照常成功且带今天四格" do
      person = create_person(create_archive())
      create_answer(person, "self_intro", "我在盛大做测试。")
      create_today(person, %{want: "想系统学 AI"})

      # 前置断言：无授权行、未寄出
      assert Repo.one(
               from(t in "flashback_todays",
                 where: t.person_id == ^Ecto.UUID.dump!(person.id),
                 select: t.sent_to_wall_at
               )
             ) == nil

      assert {:ok, %{enabled: true, share_id: share_id}} =
               CardSharing.set(true, {:person, person.id})

      card = SharedCard.get(share_id)
      assert Enum.map(card.answers, & &1.question_key) == ["self_intro"]
      assert Enum.map(card.today, & &1.question_key) == ["today.want"]
    end

    test "授权档 off 不影响分享（与金句墙口径无关）" do
      person = create_person(create_archive())
      create_answer(person, "self_intro", "我在盛大做测试。")

      Flashback.QuoteLicense
      |> Ash.Changeset.for_create(:create, %{person_id: person.id, level: :off})
      |> Ash.create!(authorize?: false)

      assert {:ok, %{enabled: true, share_id: share_id}} =
               CardSharing.set(true, {:person, person.id})

      assert SharedCard.get(share_id) != nil
    end

    test "公开 slug 未发布不影响分享" do
      person = create_person(create_archive())
      assert reload_person(person.id).public_slug == nil

      assert {:ok, %{share_id: share_id}} = CardSharing.set(true, {:person, person.id})
      assert SharedCard.get(share_id) != nil
    end
  end

  describe "公开读面（匿名）" do
    test "未命中 / 空串 / nil → nil（不泄露存在性）" do
      assert SharedCard.get("0" |> String.duplicate(48)) == nil
      assert SharedCard.get("") == nil
      assert SharedCard.get(nil) == nil
    end

    test "关闭态 → nil；删除态 → nil（删除撤链 + 两列清空）" do
      person = create_person(create_archive())
      create_answer(person, "self_intro", "我在盛大做测试。")

      assert {:ok, %{share_id: share_id}} = CardSharing.set(true, {:person, person.id})
      assert SharedCard.get(share_id) != nil

      assert {:ok, _} = CardSharing.set(false, {:person, person.id})
      assert SharedCard.get(share_id) == nil

      assert {:ok, _} = CardSharing.set(true, {:person, person.id})

      assert {:ok, %{deleted: true}} = Deletion.delete(%{person: person}, "DELETE")

      assert SharedCard.get(share_id) == nil
      deleted = reload_person(person.id)
      assert deleted.card_share_slug == nil
      assert deleted.card_share_enabled_at == nil
    end

    test "实时数据：开启后新增答案 / 更新今天，读面立刻反映（无快照）" do
      person = create_person(create_archive())
      assert {:ok, %{share_id: share_id}} = CardSharing.set(true, {:person, person.id})

      assert SharedCard.get(share_id).answers == []

      create_answer(person, "os", "Ubuntu 14.04")
      create_today(person, %{say: "十周年快乐！"})

      card = SharedCard.get(share_id)
      assert Enum.map(card.answers, & &1.question_key) == ["os"]
      assert Enum.map(card.today, & &1.question_key) == ["today.say"]
    end
  end

  describe "与旧档案互操作（无分享列的历史行）" do
    test "历史行读面不受影响：capsule 仍出 me，分享态为未开启" do
      archive = create_archive()
      person = create_person(archive)
      create_answer(person, "self_intro", "我在盛大做测试。")

      person_map = %{
        id: person.id,
        archive_event_id: archive.id,
        full_name: person.full_name,
        surname: person.surname,
        city: person.city,
        occupation_then: person.occupation_then,
        role: person.role,
        participation: person.participation,
        applied_at: person.applied_at,
        user_id: person.user_id
      }

      assert {:ok, capsule} = Cgc2046.Flashback.AlumniProjection.capsule(%{person: person_map})

      assert capsule.me.full_name == "王小明"
      assert capsule.me.card_sharing.enabled == false
      assert capsule.me.card_sharing.share_id == nil
      # 预览仍可用（本人面独立于公开门），隐名口径与名册一致
      assert capsule.me.card_sharing.preview.display_name == "王**"
    end

    test "隐名口径单源：surname 缺失时按 full_name 首字符兜底" do
      person = create_person(create_archive(), %{full_name: "李雷", surname: nil})
      create_answer(person, "self_intro", "我是李雷。")

      assert {:ok, %{share_id: share_id}} = CardSharing.set(true, {:person, person.id})
      assert SharedCard.get(share_id).display_name == "李*"
    end
  end
end
