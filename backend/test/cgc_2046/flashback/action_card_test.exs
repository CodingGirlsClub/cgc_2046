defmodule Cgc2046.Flashback.ActionCardTest do
  @moduledoc """
  U7/R13/KTD5 —— Action 卡四态状态机与成场对接。

  覆盖：非法转移拒绝（含跳态）、非管理员建卡/成场被拒、成场完整编排（Event
  open+public + 挂 1024 Initiative + 回填 event_id + 出现在 Initiative 公开
  投影）、首条附议 proposed→forming、成场通知通道分派（注册者 Fanout 订阅
  消息 job / 未注册附议者 outreach 邮件）、成场通知幂等、done 回贴照片
  data-URL 校验。

  沙箱纪律：notifications/outreach 均为 Oban testing :manual（断言入队 +
  perform_job 执行）；邮件走 Swoosh.Adapters.Test。
  """

  use Cgc2046Web.ConnCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  import Ecto.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{ActionCard, ActionCards, Endorsements, Person}
  alias Cgc2046.Flashback.Workers.{ActionFanoutWorker, OutreachWorker}
  alias Cgc2046.Initiatives
  alias Cgc2046.Repo

  @moduletag :capture_log

  @email "endorser@example.com"

  # ── 状态机（R13 四态线性） ───────────────────────────────────────────

  describe "四态状态机" do
    test "首条附议：proposed → forming；再附议不重复转移" do
      admin = Fixtures.platform_admin("card-forming-admin")
      card = create_card(admin, %{title: "骑行场", city: "北京"})
      token = issue_token(card_person(card))

      assert {:ok, %{status: :forming, first_time: true}} =
               Endorsements.endorse(token, card.id, "organizer")

      assert reload_card(card).status == :forming

      # 幂等：已 forming 再附议（另一人）不再转移，仍是 forming
      other = card_person(card, "13900000002")
      token2 = issue_token(other)

      assert {:ok, %{status: :forming, first_time: true}} =
               Endorsements.endorse(token2, card.id, nil)

      assert reload_card(card).status == :forming
    end

    test "非法转移拒绝：proposed → scheduled（跳态）、done → 任意" do
      admin = Fixtures.platform_admin("card-transition-admin")
      workspace = Fixtures.create_workspace(admin)
      initiative = open_initiative(admin)

      # proposed 卡直接成场：拒绝（须先附议）
      card = create_card(admin, %{title: "无人机航拍场", city: "上海"})

      assert {:error, %{code: "flashback_invalid_transition"}} =
               ActionCards.schedule(admin, card.id, schedule_params(workspace, initiative))

      # done 卡再成场：拒绝
      done_card = scheduled_card(admin, workspace, initiative)
      assert {:ok, _} = ActionCards.mark_done(admin, done_card.id, %{recap: "圆满"})

      assert {:error, %{code: "flashback_invalid_transition"}} =
               ActionCards.schedule(admin, done_card.id, schedule_params(workspace, initiative))

      # done → done 也拒绝（终态）
      assert {:error, %{code: "flashback_invalid_transition"}} =
               ActionCards.mark_done(admin, done_card.id, %{recap: "again"})
    end
  end

  # ── 管理员门控（KTD5：PlatformAdmin） ────────────────────────────────

  describe "非管理员被拒（建卡 / 成场 / 回贴）" do
    test "nil 与普通用户 → flashback_forbidden；平台管理员通过" do
      admin = Fixtures.platform_admin("card-gate-admin")
      plain = Fixtures.register_user("card-gate-plain")

      assert {:error, %{code: "flashback_forbidden"}} =
               ActionCards.create_card(nil, %{title: "x"})

      assert {:error, %{code: "flashback_forbidden"}} =
               ActionCards.create_card(plain, %{title: "x"})

      assert {:ok, %ActionCard{status: :proposed}} =
               ActionCards.create_card(admin, %{title: "合法卡", city: "北京"})

      assert {:error, %{code: "flashback_forbidden"}} =
               ActionCards.schedule(plain, Ecto.UUID.generate(), %{})

      assert {:error, %{code: "flashback_forbidden"}} =
               ActionCards.mark_done(plain, Ecto.UUID.generate(), %{})
    end
  end

  # ── 成场编排（KTD5 全序列） ──────────────────────────────────────────

  describe "管理员确认成场" do
    test "Event open + public + 挂 1024 Initiative + 回填 event_id + 出现在 Initiative 公开投影" do
      admin = Fixtures.platform_admin("card-schedule-admin")
      workspace = Fixtures.create_workspace(admin)
      initiative = open_initiative(admin)
      card = forming_card(admin, workspace, initiative)

      assert {:ok, result} =
               ActionCards.schedule(admin, card.id, schedule_params(workspace, initiative))

      assert result.status == "scheduled"
      assert result.event_id

      # Event 为 open + public 且挂载 Initiative
      event = event_by_id(result.event_id)
      assert event.status == :open
      assert event.visibility == :public
      assert event.initiative_id == initiative.id
      assert event.workspace_id == workspace.id

      # KTD5 验收：成场后 Event 出现在 Initiative 公开投影（fetch_events 只挂 open+public）
      assert {:ok, %{cities: cities}} = Initiatives.Public.get_by_slug(initiative.slug)
      projected = cities |> Enum.flat_map(& &1.events) |> Enum.map(& &1.id)
      assert result.event_id in projected

      # 成场通知 job 入队（幂等锚点只带 card_id）
      assert_enqueued(worker: ActionFanoutWorker, args: %{"card_id" => card.id})
    end

    test "成场通知幂等：重复入队被 unique 吞" do
      admin = Fixtures.platform_admin("card-unique-admin")
      workspace = Fixtures.create_workspace(admin)
      initiative = open_initiative(admin)
      card = forming_card(admin, workspace, initiative)

      {:ok, _} = ActionCards.schedule(admin, card.id, schedule_params(workspace, initiative))
      {:ok, _} = ActionCards.schedule(admin, card.id, schedule_params(workspace, initiative))

      assert [_job] = all_enqueued(worker: ActionFanoutWorker)
    end

    test "挂载的 Initiative 非 open → initiative_not_open（Event 留 draft，卡仍 forming）" do
      admin = Fixtures.platform_admin("card-notopen-admin")
      workspace = Fixtures.create_workspace(admin)
      initiative = draft_initiative(admin)
      card = forming_card(admin, workspace, initiative)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               ActionCards.schedule(admin, card.id, schedule_params(workspace, initiative))

      assert Enum.any?(errors, fn e ->
               Map.get(e, :code) == "initiative_not_open" or
                 String.contains?(Map.get(e, :message) || "", "initiative must be open")
             end)

      # Event 未建成（挂载守卫在 create 阶段拦截）：卡仍 forming、无 event_id
      reloaded = reload_card(card)
      assert reloaded.status == :forming
      assert reloaded.event_id == nil

      # Initiative 打开后重试同一调用：成场成功（首次建场，无重复窗口）
      {:ok, _} =
        initiative
        |> Ash.Changeset.for_update(:open, %{}, actor: admin)
        |> Ash.update(actor: admin)

      assert {:ok, %{status: "scheduled"}} =
               ActionCards.schedule(admin, card.id, schedule_params(workspace, initiative))

      assert event_by_id(reload_card(card).event_id).status == :open
    end
  end

  # ── 成场通知通道分派（KTD5/R13a） ───────────────────────────────────

  describe "成场通知通道分派" do
    test "注册附议者 → Fanout 订阅消息 job；未注册附议者 → outreach 邮件（U7 验收项）" do
      admin = Fixtures.platform_admin("card-fanout-admin")
      workspace = Fixtures.create_workspace(admin)
      initiative = open_initiative(admin)
      card = forming_card(admin, workspace, initiative)

      # 注册者：附议 + person.user_id 绑定 + wechat 身份（走 Fanout / 订阅消息）
      bound_person = card_person(card, "13900000010")
      user = Fixtures.register_user("card-fanout-bound")
      insert_wechat_identity(user)
      bind_user(bound_person, user)
      {:ok, _} = Endorsements.endorse(issue_token(bound_person), card.id, nil)

      # 未注册者：附议 + 走 U8 outreach 邮件
      unbound_person = card_person(card, "13900000011", @email)
      {:ok, _} = Endorsements.endorse(issue_token(unbound_person), card.id, nil)

      assert {:ok, _} =
               ActionCards.schedule(admin, card.id, schedule_params(workspace, initiative))

      assert :ok = perform_job(ActionFanoutWorker, %{"card_id" => card.id})

      # 注册者：flashback_action_scheduled 的 NotificationWorker job（template 携带）
      bound_jobs = all_scheduled_notifications()

      assert Enum.any?(
               bound_jobs,
               &(&1.args["template_key"] == "flashback_action_scheduled" and
                   &1.args["user_id"] == user.id)
             )

      # 未注册者：outreach job → 执行后收到成场邮件（含活动页链接与退订页脚）
      assert [{:ok, :email}] =
               [
                 %{
                   "person_id" => unbound_person.id,
                   "channel" => "email",
                   "batch" => "card-" <> card.id,
                   "template" => "action_scheduled",
                   "card_id" => card.id
                 }
               ]
               |> Enum.map(&perform_job(OutreachWorker, &1))

      assert_receive {:email, email}, 1_000
      assert email.to |> List.first() |> elem(1) == @email
      assert email.subject =~ "骑行场"
      assert email.html_body =~ "/zh-CN/events/"
      assert email.html_body =~ "/api/flashback/unsubscribe?t="
    end
  end

  # ── done 回贴（R13 照片回流） ───────────────────────────────────────

  describe "done 回贴" do
    test "photo data-URL 校验：合法通过；MIME 拒绝；超限拒绝" do
      admin = Fixtures.platform_admin("card-done-admin")
      workspace = Fixtures.create_workspace(admin)
      initiative = open_initiative(admin)
      card = scheduled_card(admin, workspace, initiative)

      png = "data:image/png;base64," <> String.duplicate("a", 128)

      assert {:ok, %{status: "done"}} =
               ActionCards.mark_done(admin, card.id, %{photo_url: png, recap: "1024 圆满"})

      reloaded = reload_card(card)
      assert reloaded.photo_url == png
      assert reloaded.recap == "1024 圆满"

      # 非图片 MIME 拒绝
      other = scheduled_card(admin, workspace, initiative, "第二场")
      svg = "data:image/svg+xml;base64,PHN2Zy8+"

      assert {:error, %{code: "flashback_photo_invalid"}} =
               ActionCards.mark_done(admin, other.id, %{photo_url: svg})

      # 超限拒绝（> 3MB）
      big = "data:image/png;base64," <> String.duplicate("a", 3_000_001)

      assert {:error, %{code: "flashback_photo_too_large"}} =
               ActionCards.mark_done(admin, other.id, %{photo_url: big})

      # http(s) URL 合法
      assert {:ok, _} =
               ActionCards.mark_done(admin, other.id, %{
                 photo_url: "https://cdn.example.com/p.webp"
               })
    end
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp create_card(admin, attrs) do
    {:ok, card} = ActionCards.create_card(admin, attrs)
    card
  end

  defp forming_card(admin, _workspace, _initiative, title \\ "骑行场") do
    card = create_card(admin, %{title: title, city: "北京"})
    token = issue_token(card_person(card))
    {:ok, _} = Endorsements.endorse(token, card.id, "promoter")
    reload_card(card)
  end

  defp scheduled_card(admin, workspace, initiative, title \\ "已排场") do
    card = forming_card(admin, workspace, initiative, title)
    {:ok, _} = ActionCards.schedule(admin, card.id, schedule_params(workspace, initiative))
    reload_card(card)
  end

  defp schedule_params(workspace, initiative) do
    %{
      workspace_id: workspace.id,
      initiative_slug: initiative.slug,
      starts_at: DateTime.add(DateTime.utc_now(), 30 * 24 * 3600)
    }
  end

  defp open_initiative(admin) do
    initiative = draft_initiative(admin)

    {:ok, opened} =
      initiative |> Ash.Changeset.for_update(:open, %{}, actor: admin) |> Ash.update(actor: admin)

    opened
  end

  defp draft_initiative(admin) do
    alias Cgc2046.Initiatives.{Initiative, InitiativeRule}

    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "1024 Programmers' Day",
        slug: "1024-#{System.unique_integer([:positive])}",
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    # :open 门：四条规则须齐（initiative.ex 的 open 守卫）
    for {key, value, locked} <- [
          {:deposit, %{enabled: false}, true},
          {:age_gate, %{min_age: 18}, true},
          {:min_participants, %{count: 8}, false},
          {:deadline_rule, %{hours_before_start: 72}, false}
        ] do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: locked
      })
      |> Ash.create!(actor: admin)
    end

    initiative
  end

  defp card_person(_card, phone \\ "13900000001", email \\ "person@example.com") do
    archive =
      Flashback.EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "2014-01-11-bj-#{System.unique_integer([:positive])}",
        name: "Rails Girls Beijing",
        city: "北京",
        occurred_on: ~D[2014-01-11]
      })
      |> Ash.create!(authorize?: false)

    Person
    |> Ash.Changeset.for_create(:create, %{
      archive_event_id: archive.id,
      full_name: "附议人",
      surname: "附",
      role: :learner,
      participation: :attended,
      phone: phone,
      email: email
    })
    |> Ash.create!(authorize?: false)
  end

  # 测试专用明文 token（不经 outreach worker 铸造——U2 测试同款）
  defp issue_token(person) do
    alias Cgc2046.Accounts.TokenCredential
    alias Cgc2046.Flashback.Token

    value = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = TokenCredential.hash(value)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    value
  end

  # UserIdentity（Fanout.deliver 需要平台身份；consent 不预置——发送时按
  # 剩余配额分派，job 断言不依赖配额）。
  defp insert_wechat_identity(user) do
    alias Cgc2046.Accounts.UserIdentity

    UserIdentity
    |> Ash.Changeset.for_create(:upsert, %{
      provider: :wechat,
      uid: "wx-card-#{System.unique_integer([:positive])}",
      user_id: user.id
    })
    |> Ash.create!(authorize?: false)
  end

  defp bind_user(person, user) do
    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.update(authorize?: false)
  end

  defp reload_card(card) do
    ActionCard
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^card.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp event_by_id(event_id) do
    alias Cgc2046.Events.Event

    case Ash.get(Event, event_id, authorize?: false) do
      {:ok, event} -> event
      _ -> flunk("event #{event_id} not found")
    end
  end

  # NotificationWorker 已入队 job（过滤成场模板）
  defp all_scheduled_notifications do
    from(j in Oban.Job,
      where:
        j.worker == "Cgc2046.Notifications.NotificationWorker" and
          fragment("args->>'template_key' = ?", "flashback_action_scheduled"),
      select: %{args: j.args}
    )
    |> Repo.all()
  end
end
