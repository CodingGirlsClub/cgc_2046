defmodule Cgc2046.Flashback.AlumniProjectionTest do
  @moduledoc """
  U5 校友层投影测试（KTD3/R12/R13/R30）：

  - 结构化层满员：attended 全量在名册、姓氏隐名「王\*\*」；未入选者不在名册；
  - 内容层待点亮：未寄出者 today=nil + answers=[]（零文本泄露）；
  - 寄出者内容显影（雾化版：▓▓ 遮蔽、原文字符不出现）；
  - 撤回后呈现：名册回到结构化卡 + 虚线内容位、「今天」格回虚线；
  - 行动板计数与 endorsed_by_me / roles_claimed；
  - 附议幂等（一人一卡一行，再点改角色不重复计数）。

  手机/邮箱零出现在任何投影（KTD3 白名单断言）。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.Flashback

  alias Cgc2046.Flashback.{
    ActionCard,
    AlumniProjection,
    Endorsement,
    Endorsements,
    Person,
    QuoteLicense,
    Token
  }

  alias Cgc2046.Repo

  defp create_archive(attrs \\ %{}) do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          key: "2014-01-11-bj",
          name: "Rails Girls Beijing",
          city: "北京",
          occurred_on: ~D[2014-01-11],
          applied_count: 344,
          attended_count: 102
        },
        attrs
      )
    )
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

  defp create_answer(person, key \\ "self_intro", text \\ "在盛大做测试。喜欢周末骑行。", fog_spans \\ nil) do
    Flashback.Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: key,
      raw_text: text,
      fog_spans: fog_spans
    })
    |> Ash.create!(authorize?: false)
  end

  # sent_to_wall_at 只在 update action 接受（U2 语义）：先建行再落寄出态
  defp upsert_today(person, attrs) do
    today =
      Flashback.Today
      |> Ash.Changeset.for_create(:create, %{person_id: person.id})
      |> Ash.create!(authorize?: false)

    if attrs != %{} do
      today
      |> Ash.Changeset.for_update(:update, attrs)
      |> Ash.update!(authorize?: false)
    end
  end

  defp issue_token(person) do
    plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end

  defp capsule_for(token, city \\ nil) do
    {:ok, %{person: person}} = AlumniProjection.resolve_person(token, nil)
    {:ok, capsule} = AlumniProjection.capsule(%{person: person}, city)
    capsule
  end

  describe "分层墙（R12）" do
    test "结构化层满员：attended 全量在名册、姓氏隐名；未入选者不在名册；PII 零出现" do
      archive = create_archive()
      sent = create_person(archive, %{full_name: "王寄出", surname: "王"})
      quiet = create_person(archive, %{full_name: "李安静", surname: "李"})

      _dreamer =
        create_person(archive, %{full_name: "赵未选", surname: "赵", participation: :not_selected})

      upsert_today(sent, %{sent_to_wall_at: DateTime.utc_now()})

      capsule = capsule_for(issue_token(sent))

      [archive_payload] = capsule.archives
      assert length(archive_payload.roster) == 2
      assert archive_payload.attended_count == 102
      assert archive_payload.is_mine

      masked = Enum.map(archive_payload.roster, & &1.surname_masked)
      assert "王**" in masked
      assert "李**" in masked
      refute "赵**" in masked

      # 手机/邮箱零出现（KTD3 白名单）
      payload = inspect(capsule)
      refute payload =~ "13900000001"
      refute payload =~ "@example.com"
    end

    test "内容层：未寄出者 today=nil + answers=[]；寄出者雾化显影（原文不出现）" do
      archive = create_archive()
      mine = create_person(archive, %{})
      other = create_person(archive, %{full_name: "李安静", surname: "李"})

      create_answer(mine, "self_intro", "在盛大做测试。喜欢周末骑行。", [%{"start" => 0, "len" => 6}])
      upsert_today(other, %{})
      upsert_today(mine, %{sent_to_wall_at: DateTime.utc_now(), now_status: "还在写代码"})

      capsule = capsule_for(issue_token(mine))
      [archive_payload] = capsule.archives

      mine_entry = Enum.find(archive_payload.roster, &(&1.surname_masked == "王**"))
      other_entry = Enum.find(archive_payload.roster, &(&1.surname_masked == "李**"))

      # 寄出者：内容显影（雾面段已遮蔽，原文字符不出现）
      assert mine_entry.today.now_status == "还在写代码"
      [answer] = mine_entry.answers
      assert answer.question_key == "self_intro"
      assert answer.text == "▓▓。喜欢周末骑行。"
      refute answer.text =~ "在盛大做测试"

      # 未寄出者：内容层为空（前端渲染虚线位）
      assert is_nil(other_entry.today)
      assert other_entry.answers == []
    end

    test "撤回后三处呈现：名册回结构化卡、内容清空、「今天」格回虚线（R30）" do
      archive = create_archive()
      mine = create_person(archive, %{})

      create_answer(mine, "funny_thing", "给自己买了台二手 ThinkPad。")
      upsert_today(mine, %{sent_to_wall_at: DateTime.utc_now(), want: "想学 AI"})

      token = issue_token(mine)
      assert {:ok, %{retracted: true}} = Cgc2046.Flashback.Tokens.retract(token)

      capsule = capsule_for(token)
      [archive_payload] = capsule.archives
      mine_entry = Enum.find(archive_payload.roster, &(&1.surname_masked == "王**"))

      assert is_nil(mine_entry.sent_to_wall_at)
      assert is_nil(mine_entry.today)
      assert mine_entry.answers == []
      assert is_nil(capsule.me.today.sent_to_wall_at)
    end
  end

  describe "行动板（R13）" do
    test "四态卡计数、endorsed_by_me 与 roles_claimed" do
      archive = create_archive()
      me = create_person(archive, %{})
      other = create_person(archive, %{full_name: "李安静", surname: "李"})

      proposed =
        ActionCard
        |> Ash.Changeset.for_create(:create, %{
          title: "骑行场",
          city: "北京",
          proposer_person_id: me.id
        })
        |> Ash.create!(authorize?: false)

      forming =
        ActionCard
        |> Ash.Changeset.for_create(:create, %{title: "潜水场", city: "上海"})
        |> Ash.create!(authorize?: false)

      Endorsement
      |> Ash.Changeset.for_create(:create, %{
        card_id: forming.id,
        person_id: me.id,
        role_claimed: "organizer"
      })
      |> Ash.create!(authorize?: false)

      Endorsement
      |> Ash.Changeset.for_create(:create, %{card_id: proposed.id, person_id: other.id})
      |> Ash.create!(authorize?: false)

      capsule = capsule_for(issue_token(me))
      by_title = Enum.map(capsule.action_cards, &{&1.title, &1}) |> Map.new()

      assert by_title["骑行场"].endorsement_count == 1
      assert by_title["骑行场"].endorsed_by_me == false
      assert by_title["骑行场"].status == "proposed"

      assert by_title["潜水场"].endorsement_count == 1
      assert by_title["潜水场"].endorsed_by_me == true
      assert by_title["潜水场"].roles_claimed == ["organizer"]
    end
  end

  describe "附议写面（R13）" do
    test "首次附议 first_time=true；再次点击改角色不重复计数" do
      archive = create_archive()
      me = create_person(archive, %{})

      card =
        ActionCard
        |> Ash.Changeset.for_create(:create, %{title: "骑行场", city: "北京"})
        |> Ash.create!(authorize?: false)

      token = issue_token(me)

      assert {:ok, %{first_time: true, role_claimed: "promoter"}} =
               Endorsements.endorse(token, card.id, "promoter")

      assert {:ok, %{first_time: false, role_claimed: "organizer"}} =
               Endorsements.endorse(token, card.id, "organizer")

      count =
        Repo.aggregate(
          Ecto.Query.from(e in "flashback_endorsements",
            where: e.card_id == ^Ecto.UUID.dump!(card.id)
          ),
          :count
        )

      assert count == 1

      capsule = capsule_for(token)
      [card_payload] = capsule.action_cards
      assert card_payload.endorsement_count == 1
      assert card_payload.roles_claimed == ["organizer"]
    end

    test "非法角色与不存在的卡被拒" do
      archive = create_archive()
      me = create_person(archive, %{})
      token = issue_token(me)

      card =
        ActionCard
        |> Ash.Changeset.for_create(:create, %{title: "骑行场", city: "北京"})
        |> Ash.create!(authorize?: false)

      assert {:error, %{code: "flashback_invalid_input"}} =
               Endorsements.endorse(token, card.id, "hacker")

      assert {:error, %{code: "flashback_card_not_found"}} =
               Endorsements.endorse(token, Ecto.UUID.generate(), nil)
    end
  end

  describe "身份双入口（R28 回访正门）" do
    test "无 token 未登录 → auth_required；登录未绑定 → not_bound" do
      assert {:error, %{code: "flashback_auth_required"}} =
               AlumniProjection.resolve_person(nil, nil)

      actor = %{id: Ecto.UUID.generate()}

      assert {:error, %{code: "flashback_person_not_bound"}} =
               AlumniProjection.resolve_person(nil, actor)
    end

    test "登录态（user_id 绑定）可进胶囊" do
      archive = create_archive()
      user_id = Ecto.UUID.generate()
      # user_id 不可由 create 写入（R27 只经绑定通道置位）——测试直接落列
      me =
        create_person(archive, %{})
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:user_id, user_id)
        |> Ash.update!(authorize?: false)

      assert {:ok, %{person: person, via: :account}} =
               AlumniProjection.resolve_person(nil, %{id: user_id})

      assert person.id == me.id
    end
  end

  describe "金句授权档（R31）" do
    test "无授权行为 off；设置后 capsule me 回读档位" do
      archive = create_archive()
      me = create_person(archive, %{})

      capsule = capsule_for(issue_token(me))
      assert capsule.me.quote_level == "off"

      QuoteLicense
      |> Ash.Changeset.for_create(:create, %{person_id: me.id, level: :anonymous})
      |> Ash.create!(authorize?: false)

      assert capsule_for(issue_token(me)).me.quote_level == "anonymous"
    end
  end

  describe "城市钉（R34）" do
    test "cities 投影：名册城市 ∪ 行动卡城市，去重排序；未入选者城市不进" do
      archive = create_archive()
      create_person(archive, %{})
      create_person(archive, %{full_name: "李安静", surname: "李", city: "上海"})

      create_person(archive, %{
        full_name: "赵未选",
        surname: "赵",
        city: "广州",
        participation: :not_selected
      })

      ActionCard
      |> Ash.Changeset.for_create(:create, %{title: "杭州骑行", city: "杭州"})
      |> Ash.create!(authorize?: false)

      capsule =
        capsule_for(issue_token(create_person(archive, %{full_name: "周发起", surname: "周"})))

      # "上海" < "北京" < "杭州"（UTF-8 字节序）；广州（not_selected）不在
      assert capsule.cities == ["上海", "北京", "杭州"]
    end

    test "city 过滤：roster 按人城市、行动卡按卡城市、筛空场次整架撤下；cities 不随过滤收缩" do
      bj_archive =
        create_archive(%{key: "2014-01-11-bj", name: "Rails Girls Beijing", city: "北京"})

      sh_archive =
        create_archive(%{key: "2013-05-18-sh", name: "Rails Girls Shanghai", city: "上海"})

      me = create_person(bj_archive, %{city: "北京"})
      create_person(bj_archive, %{full_name: "李安静", surname: "李", city: "上海"})
      create_person(sh_archive, %{full_name: "张广州", surname: "张", city: "广州"})

      ActionCard
      |> Ash.Changeset.for_create(:create, %{title: "骑行场", city: "北京", proposer_person_id: me.id})
      |> Ash.create!(authorize?: false)

      ActionCard
      |> Ash.Changeset.for_create(:create, %{title: "潜水场", city: "上海"})
      |> Ash.create!(authorize?: false)

      capsule = capsule_for(issue_token(me), "上海")

      # 名册按**人**的城市筛：北京场次里的上海人保留（场次城市是北京），
      # 上海场次无人命中（张广州是广州人）→ 整架撤下
      [only] = capsule.archives
      assert only.key == "2014-01-11-bj"
      assert Enum.map(only.roster, & &1.surname_masked) == ["李**"]

      assert Enum.map(capsule.action_cards, & &1.title) == ["潜水场"]

      # 钉条数据源不随过滤收缩（否则选定城市后其余钉消失，无法切回全部）
      assert capsule.cities == ["上海", "北京", "广州"]

      # 未筛：全量名册（3 人 2 场）与 2 卡
      all = capsule_for(issue_token(me))
      assert length(all.archives) == 2
      assert Enum.map(all.archives, &length(&1.roster)) |> Enum.sum() == 3
      assert length(all.action_cards) == 2
    end

    test "空串 city 视为未筛（query 变量空串不筛）" do
      archive = create_archive()
      me = create_person(archive, %{})

      capsule = capsule_for(issue_token(me), "")
      assert capsule == capsule_for(issue_token(me))
    end
  end
end
