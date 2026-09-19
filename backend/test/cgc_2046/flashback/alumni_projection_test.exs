defmodule Cgc2046.Flashback.AlumniProjectionTest do
  @moduledoc """
  U5 校友层投影测试（KTD3/R12/R13/R30）：

  - 结构化层满员：attended 全量在名册、姓氏隐名「王\*\*」；未入选者不在名册；
  - 内容层待点亮：未寄出者 today=nil + answers=[]（零文本泄露）；
  - 寄出者内容显影（雾化版：▓▓ 遮蔽、原文字符不出现）；
  - 撤回后呈现：名册回到结构化卡 + 虚线内容位、「今天」格回虚线；
  - 附议幂等（一人一卡一行，再点改角色不重复计数）。

  手机/邮箱零出现在任何投影（KTD3 白名单断言）。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.Flashback

  alias Cgc2046.Flashback.{
    AlumniProjection,
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

      # 段结构（雾化升级）：fog 段零字符（原文字符不出投影），明文段完整
      fog = Enum.find(answer.segments, & &1.fog)
      plain = Enum.find(answer.segments, &(!&1.fog))
      assert fog.len == 6 and fog.text == ""
      assert plain.text == "。喜欢周末骑行。"
      refute inspect(answer.segments) =~ "在盛大做测试"

      # 未寄出者：内容层为空（前端渲染虚线位）
      assert is_nil(other_entry.today)
      assert other_entry.answers == []
    end

    test "社交媒体不出墙（用户拍板）：寄出者的 social_media 答案不进名册投影" do
      archive = create_archive()
      mine = create_person(archive, %{email: "s@example.com"})

      # 本人：社交答案 + 寄出
      create_answer(mine, "social_media", "http://weibo.com/someone")
      create_answer(mine, "self_intro", "一句普通自我介绍。")
      upsert_today(mine, %{sent_to_wall_at: DateTime.utc_now()})

      capsule = capsule_for(issue_token(mine))
      [archive_payload] = capsule.archives
      mine_entry = Enum.find(archive_payload.roster, &(&1.surname_masked == "王**"))

      # 墙上只有 self_intro；social_media 键零出现（含段内/键名）
      keys = Enum.map(mine_entry.answers, & &1.question_key)
      assert keys == ["self_intro"]
      # 墙面（名册）整体零出现；本人 me 面另断言保留
      roster_payload = inspect(archive_payload.roster)
      refute roster_payload =~ "weibo.com"
      refute roster_payload =~ "social_media"

      # me（本人导出面）保留完整键集——用户口径：本人显影/导出不受影响
      me_keys = Enum.map(capsule.me.answers, & &1.question_key) |> Enum.sort()
      assert "social_media" in me_keys
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
    test "cities 投影：名册 ∪ 未来场次 ∪ 公开许愿三源，去重排序；未入选者/私有许愿城市不进（KTD6）" do
      archive = create_archive()
      create_person(archive, %{})
      create_person(archive, %{full_name: "李安静", surname: "李", city: "上海"})

      create_person(archive, %{
        full_name: "赵未选",
        surname: "赵",
        city: "广州",
        participation: :not_selected
      })

      capsule =
        capsule_for(issue_token(create_person(archive, %{full_name: "周发起", surname: "周"})))

      # "上海" < "北京"（UTF-8 字节序）；广州（not_selected）不在
      assert capsule.cities == ["上海", "北京"]

      # 三源各自可区分：未入选者城市不进名册源；其**公开许愿**城市进 wish 源
      # （成都）；私有许愿城市（西安）不进；未来场次城市（杭州）进
      ws =
        case Cgc2046.Repo.query!("SELECT id FROM workspaces LIMIT 1") do
          %{rows: [[id]]} -> id
          _ -> Ecto.UUID.generate()
        end

      Cgc2046.Repo.query!(
        """
        WITH i AS (
          INSERT INTO initiatives (id, slug, name, status, inserted_at, updated_at)
          VALUES (gen_random_uuid(), 'city-pin-init', '城市钉场次', 'open', now(), now())
          RETURNING id
        )
        INSERT INTO events (id, slug, title, status, visibility, starts_at, venue, initiative_id, workspace_id, inserted_at, updated_at)
        SELECT gen_random_uuid(), 'city-pin-ev', '场次', 'open', 'public', now() + interval '30 days',
               jsonb_build_object('country', '中国', 'province', '-', 'city', '杭州', 'district', '-'),
               i.id, $1::uuid, now(), now()
        FROM i
        """,
        [ws]
      )

      wisher =
        create_person(archive, %{
          full_name: "许愿人",
          surname: "许",
          city: "成都",
          participation: :not_selected
        })

      {:ok, _} = Cgc2046.Flashback.Wishes.create_wish(wisher.id, "公开愿望", "public")

      private_person =
        create_person(archive, %{
          full_name: "私愿人",
          surname: "私",
          city: "西安",
          participation: :not_selected
        })

      {:ok, _} = Cgc2046.Flashback.Wishes.create_wish(private_person.id, "私愿", "private")

      capsule2 =
        capsule_for(issue_token(create_person(archive, %{full_name: "周发起", surname: "周"})))

      assert "杭州" in capsule2.cities
      assert "成都" in capsule2.cities
      refute "西安" in capsule2.cities
    end

    test "city 过滤：roster 按人城市、筛空场次整架撤下；cities 不随过滤收缩" do
      bj_archive =
        create_archive(%{key: "2014-01-11-bj", name: "Rails Girls Beijing", city: "北京"})

      sh_archive =
        create_archive(%{key: "2013-05-18-sh", name: "Rails Girls Shanghai", city: "上海"})

      me = create_person(bj_archive, %{city: "北京"})
      create_person(bj_archive, %{full_name: "李安静", surname: "李", city: "上海"})
      create_person(sh_archive, %{full_name: "张广州", surname: "张", city: "广州"})

      capsule = capsule_for(issue_token(me), "上海")

      # 名册按**人**的城市筛：北京场次里的上海人保留（场次城市是北京），
      # 上海场次无人命中（张广州是广州人）→ 整架撤下
      [only] = capsule.archives
      assert only.key == "2014-01-11-bj"
      assert Enum.map(only.roster, & &1.surname_masked) == ["李**"]

      # 钉条数据源不随过滤收缩（否则选定城市后其余钉消失，无法切回全部）
      assert capsule.cities == ["上海", "北京", "广州"]

      # 未筛：全量名册（3 人 2 场）
      all = capsule_for(issue_token(me))
      assert length(all.archives) == 2
      assert Enum.map(all.archives, &length(&1.roster)) |> Enum.sum() == 3
    end

    test "空串 city 视为未筛（query 变量空串不筛）" do
      archive = create_archive()
      me = create_person(archive, %{})

      capsule = capsule_for(issue_token(me), "")
      assert capsule == capsule_for(issue_token(me))
    end
  end
end
