defmodule Cgc2046.Flashback.ReportsTest do
  @moduledoc """
  U5 KTD5：举报 + admin set_hidden + 信用字段 + 收件箱提取。
  """
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Flashback.{Reports, Wishes}
  alias Cgc2046.Accounts.User

  defp create_archive do
    Cgc2046.Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-report-u5-#{System.unique_integer([:positive])}",
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

  defp make_admin_user(prefix) do
    user = register_user(prefix)

    Repo.query!("UPDATE users SET is_platform_admin = true WHERE id = $1", [
      Repo.uuid!(user.id)
    ])

    user
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

  defp create_listed_wish(person, content) do
    {:ok, wish} =
      Wishes.create_wish(person.id, content, "public",
        public_listing_consent: true,
        signature_choice: :anonymous
      )

    # P2-1 机审通道门后公开愿默认待审；举报目标资格 = listed——本套件聚焦举报，
    # 直挂树（等价 admin 放行 + re-list 的终态）
    Repo.query!(
      "UPDATE flashback_wishes SET listed_at = now(), hidden_at = NULL WHERE id = $1",
      [Repo.uuid!(wish.id)]
    )

    Ash.get!(Cgc2046.Flashback.Wish, wish.id, authorize?: false)
  end

  describe "公开举报" do
    test "登录 actor 举报 listed 愿望 → status=pending 入库" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "spam 内容")

      reporter = register_user("u5-reporter")

      {:ok, report} =
        Reports.report("wish", wish.id, "spam",
          actor_user_id: reporter.id,
          reason_free: "这是垃圾信息"
        )

      assert report.status == "pending"
      assert report.reason_type == "spam"
      assert report.reason_free == "这是垃圾信息"
      assert report.reporter_voter_key == "u:#{reporter.id}"
    end

    test "reporter 未登录带 anon key → 可以举报" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "spam")

      {:ok, report} =
        Reports.report("wish", wish.id, "spam", anon_voter_key: "a:dev-report-1")

      assert report.reporter_voter_key == "a:dev-report-1"
    end

    test "reason_type 不在 preset → flashback_report_invalid_reason_type" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "spam")

      assert {:error, %{code: "flashback_report_invalid_reason_type"}} =
               Reports.report("wish", wish.id, "bogus_type", anon_voter_key: "a:dev-report-x")
    end

    test "reason_free > 200 字 → flashback_report_reason_free_too_long" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "spam")

      long = String.duplicate("x", 201)

      assert {:error, %{code: "flashback_report_reason_free_too_long"}} =
               Reports.report("wish", wish.id, "spam",
                 anon_voter_key: "a:dev-report-y",
                 reason_free: long
               )
    end

    test "11 次举报被限频（10/15min/IP）→ flashback_report_rate_limited" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "spam")

      # 前 10 次同 IP 都成功
      for i <- 1..10 do
        {:ok, _} =
          Reports.report("wish", wish.id, "spam",
            anon_voter_key: "a:dev-#{i}-#{System.unique_integer([:positive])}",
            remote_ip: "10.0.0.1"
          )
      end

      # 第 11 次同 IP 被限频
      assert {:error, %{code: "flashback_report_rate_limited"}} =
               Reports.report("wish", wish.id, "spam",
                 anon_voter_key: "a:dev-99",
                 remote_ip: "10.0.0.1"
               )
    end
  end

  describe "FIX-4 举报幂等 + 目标资格收口" do
    test "同人同目标重复举报幂等：返回既有行，不重复入队" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "被举报愿")
      reporter = register_user("u5-idem")

      {:ok, first} =
        Reports.report("wish", wish.id, "spam", actor_user_id: reporter.id, remote_ip: "10.9.0.1")

      {:ok, second} =
        Reports.report("wish", wish.id, "spam",
          actor_user_id: reporter.id,
          reason_free: "第二次补充",
          remote_ip: "10.9.0.1"
        )

      assert first.id == second.id
      # 幂等返回既有行（不覆盖）
      assert second.reason_free == first.reason_free

      cnt =
        Repo.query!("SELECT COUNT(*) FROM flashback_reports WHERE target_id = $1", [
          Repo.uuid!(wish.id)
        ])

      assert cnt.rows == [[1]]
    end

    test "匿名 a: 键同人同目标也幂等" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "被匿名举报")

      {:ok, first} =
        Reports.report("wish", wish.id, "spam",
          anon_voter_key: "a:idem-dev",
          remote_ip: "10.9.0.2"
        )

      {:ok, second} =
        Reports.report("wish", wish.id, "scam",
          anon_voter_key: "a:idem-dev",
          remote_ip: "10.9.0.2"
        )

      assert first.id == second.id
    end

    test "private 愿望举报 → target_not_found（不泄露存在性）" do
      archive = create_archive()
      owner = create_person(archive)

      {:ok, private_wish} =
        Wishes.create_wish(owner.id, "悄悄话", "private", public_listing_consent: false)

      assert {:error, %{code: "flashback_report_target_not_found"}} =
               Reports.report("wish", private_wish.id, "spam",
                 anon_voter_key: "a:px",
                 remote_ip: "10.9.0.3"
               )
    end

    test "未 listed 愿望举报 → target_not_found" do
      archive = create_archive()
      owner = create_person(archive)

      {:ok, member_only} =
        Wishes.create_wish(owner.id, "成员面愿", "public", public_listing_consent: false)

      assert {:error, %{code: "flashback_report_target_not_found"}} =
               Reports.report("wish", member_only.id, "spam",
                 anon_voter_key: "a:px2",
                 remote_ip: "10.9.0.4"
               )
    end

    test "hidden 愿望举报 → target_not_found" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "将被隐藏")

      Repo.query!("UPDATE flashback_wishes SET hidden_at = now() WHERE id = $1", [
        Repo.uuid!(wish.id)
      ])

      assert {:error, %{code: "flashback_report_target_not_found"}} =
               Reports.report("wish", wish.id, "spam",
                 anon_voter_key: "a:px3",
                 remote_ip: "10.9.0.5"
               )
    end

    test "listed 公开愿望举报仍成功（正路径不回归）" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "正常可举报")

      assert {:ok, %{} = report} =
               Reports.report("wish", wish.id, "spam",
                 anon_voter_key: "a:ok",
                 remote_ip: "10.9.0.6"
               )

      assert report.status == "pending"
    end
  end

  describe "Admin set_wish_hidden + 信用字段联动" do
    test "admin set_hidden=true → wish.hidden_at 置位 + user.wishes_review_required_at 置位" do
      archive = create_archive()
      owner = create_person(archive)
      owner_user = register_user("u5-owner")
      :ok = bind_person_to_user(owner.id, owner_user.id)

      wish = create_listed_wish(owner, "spam")
      admin = make_admin_user("u5-admin")

      {:ok, hidden} = Reports.set_wish_hidden(wish.id, admin.id, true)
      assert hidden.hidden_at != nil

      %{rows: [[credit]]} =
        Repo.query!(
          "SELECT wishes_review_required_at FROM users WHERE id = $1",
          [Repo.uuid!(owner_user.id)]
        )

      assert credit != nil
    end

    test "admin set_hidden=false → 清 hidden_at；不动 user 信用字段" do
      archive = create_archive()
      owner = create_person(archive)
      owner_user = register_user("u5-owner")
      :ok = bind_person_to_user(owner.id, owner_user.id)

      wish = create_listed_wish(owner, "spam")
      admin = make_admin_user("u5-admin")

      {:ok, _} = Reports.set_wish_hidden(wish.id, admin.id, true)

      %{rows: [[credit_before]]} =
        Repo.query!(
          "SELECT wishes_review_required_at FROM users WHERE id = $1",
          [Repo.uuid!(owner_user.id)]
        )

      {:ok, unhidden} = Reports.set_wish_hidden(wish.id, admin.id, false)
      assert unhidden.hidden_at == nil

      %{rows: [[credit_after]]} =
        Repo.query!(
          "SELECT wishes_review_required_at FROM users WHERE id = $1",
          [Repo.uuid!(owner_user.id)]
        )

      # 信用字段保持（不清）——G1 pin
      assert credit_after == credit_before
    end

    test "未认领 person（user_id=NULL）set_hidden → wish 下架但不动 users 表" do
      archive = create_archive()
      # user_id=NULL by default
      owner = create_person(archive)
      wish = create_listed_wish(owner, "spam")
      admin = make_admin_user("u5-admin")

      {:ok, hidden} = Reports.set_wish_hidden(wish.id, admin.id, true)
      assert hidden.hidden_at != nil
      # 未认领 person 不动 users 表任何行——测试断言没有 SQL exception
    end

    test "未领管用户 set_hidden → flashback_auth_required" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "spam")
      non_admin = register_user("u5-pleb")

      assert {:error, %{code: "flashback_auth_required"}} =
               Reports.set_wish_hidden(wish.id, non_admin.id, true)
    end
  end

  describe "「说给主办方听」收件箱" do
    test "private 愿望携作者登录账号 phone/email" do
      archive = create_archive()
      owner = create_person(archive)
      owner_user = register_user("u5-inbox-owner")
      bind_person_to_user(owner.id, owner_user.id)

      # 更新 owner_user 的 phone/email；register_user 默认空
      Repo.query!(
        "UPDATE users SET phone = '13812340001', email = 'owner@test.com' WHERE id = $1",
        [Repo.uuid!(owner_user.id)]
      )

      {:ok, _wish} =
        Wishes.create_wish(owner.id, "悄悄话给主办方", "private",
          signature_choice: :anonymous,
          public_listing_consent: false
        )

      inbox = Reports.list_inbox_private_wishes()
      assert length(inbox) == 1
      assert hd(inbox).wish.visibility == "private"

      assert hd(inbox).wisher_user_contact == %{
               phone: "13812340001",
               email: "owner@test.com"
             }
    end
  end

  describe "Admin 举报治理" do
    test "dismiss_report 改 status=dismissed + acted_at/acted_by" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "spam")
      admin = make_admin_user("u5-admin")

      {:ok, report} = Reports.report("wish", wish.id, "spam", anon_voter_key: "a:dev-1")

      {:ok, dismissed} = Reports.dismiss_report(report.id, admin.id)
      assert dismissed.status == "dismissed"
      assert dismissed.acted_by_user_id == admin.id
      assert dismissed.acted_at != nil
    end

    test "approve_report → status=actioned + 联动 set_wish_hidden(true)" do
      archive = create_archive()
      owner = create_person(archive)
      owner_user = register_user("u5-owner-app")
      bind_person_to_user(owner.id, owner_user.id)

      wish = create_listed_wish(owner, "spam")
      admin = make_admin_user("u5-admin")

      {:ok, report} = Reports.report("wish", wish.id, "spam", anon_voter_key: "a:dev-1")

      {:ok, actioned} = Reports.approve_report(report.id, admin.id)
      assert actioned.status == "actioned"
      assert actioned.acted_by_user_id == admin.id

      %{rows: [[user_credit]]} =
        Repo.query!(
          "SELECT wishes_review_required_at FROM users WHERE id = $1",
          [Repo.uuid!(owner_user.id)]
        )

      assert user_credit != nil
    end

    test "未批准 listed_report_list_pending_reports 按插入时间正序" do
      archive = create_archive()
      owner = create_person(archive)
      wish1 = create_listed_wish(owner, "spam1")
      wish2 = create_listed_wish(owner, "spam2")

      {:ok, r1} = Reports.report("wish", wish1.id, "spam", anon_voter_key: "a:dev-1")
      :timer.sleep(10)
      {:ok, r2} = Reports.report("wish", wish2.id, "spam", anon_voter_key: "a:dev-2")

      pending = Reports.list_pending_reports()
      assert length(pending) == 2
      assert hd(pending).id == r1.id
    end
  end

  describe "#817 admin 巡检投影 list_public_wishes_for_admin" do
    test "三态标记 + 待审置前 + 未授权/软删不出现 + 信用标记与计数" do
      archive = create_archive()
      owner = create_person(archive)
      admin = make_admin_user("817-admin")

      # listed：consent 创建后 SQL 直挂（等价放行终态；新代码已写 listing_consent_at）
      {:ok, listed} =
        Wishes.create_wish(owner.id, "已挂树的愿望", "public", public_listing_consent: true)

      Repo.query!(
        "UPDATE flashback_wishes SET listed_at = now(), hidden_at = NULL WHERE id = $1",
        [Repo.uuid!(listed.id)]
      )

      # pending：信用降级作者 + consent → 创建即待审（listing_consent_at 随写）
      degraded = create_person(archive, %{full_name: "李小梅", surname: "李"})
      degraded_user = register_user("817-degraded")
      bind_person_to_user(degraded.id, degraded_user.id)

      Repo.query!(
        "UPDATE users SET wishes_review_required_at = now() WHERE id = $1",
        [Repo.uuid!(degraded_user.id)]
      )

      {:ok, pending} =
        Wishes.create_wish(degraded.id, "待审的愿望", "public", public_listing_consent: true)

      # hidden：listed 后 admin 下架（listed 保持 + hidden 置位）
      {:ok, hidden} =
        Wishes.create_wish(owner.id, "被下架的愿望", "public", public_listing_consent: true)

      Repo.query!(
        "UPDATE flashback_wishes SET listed_at = now(), hidden_at = NULL WHERE id = $1",
        [Repo.uuid!(hidden.id)]
      )

      {:ok, _} = Reports.set_wish_hidden(hidden.id, admin.id, true)

      # 未授权（consent=false）与软删：均不进巡检面——用第二作者，
      # 避开 owner 年度 3 条配额（listed/hidden 已占 2）
      extra = create_person(archive, %{full_name: "张小三", surname: "张"})

      {:ok, _no_consent} =
        Wishes.create_wish(extra.id, "未授权的公开愿", "public", public_listing_consent: false)

      {:ok, deleted} =
        Wishes.create_wish(extra.id, "已删的愿望", "public", public_listing_consent: true)

      Repo.query!(
        "UPDATE flashback_wishes SET listed_at = now(), deleted_at = now() WHERE id = $1",
        [Repo.uuid!(deleted.id)]
      )

      rows = Reports.list_public_wishes_for_admin(50)
      ids = Enum.map(rows, & &1.wish_id)

      assert pending.id in ids and hidden.id in ids and listed.id in ids
      refute deleted.id in ids
      # 未授权愿望不在巡检面（授权不扩大红线：admin 放行不可达）
      refute Enum.any?(rows, &(&1.content == "未授权的公开愿"))

      by_id = Map.new(rows, &{&1.wish_id, &1})
      assert by_id[pending.id].status == "pending_review"
      assert by_id[hidden.id].status == "hidden"
      assert by_id[listed.id].status == "listed"
      assert by_id[pending.id].author_credit_reduced == true
      assert by_id[listed.id].author_credit_reduced == false
      assert %DateTime{} = by_id[listed.id].listed_at

      # 排序：待审 → 已下架 → 已挂树
      assert [pending.id, hidden.id, listed.id] ==
               Enum.map(
                 Enum.filter(rows, &(&1.wish_id in [pending.id, hidden.id, listed.id])),
                 & &1.wish_id
               )
    end

    test "计数：期待/附议随行（listed 愿望真实路径附议 + SQL 期待）" do
      archive = create_archive()
      owner = create_person(archive)
      endorser = register_user("817-endorser")

      {:ok, wish} =
        Wishes.create_wish(owner.id, "有附议的愿望", "public", public_listing_consent: true)

      Repo.query!(
        "UPDATE flashback_wishes SET listed_at = now(), hidden_at = NULL WHERE id = $1",
        [Repo.uuid!(wish.id)]
      )

      {:ok, _} =
        Wishes.endorse_by_user(endorser.id, wish.id,
          contribution_types: ["venue"],
          message: "可以提供场地"
        )

      Repo.query!(
        """
        INSERT INTO flashback_wish_expectations (id, wish_id, voter_key, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, 'u:817-patrol', now(), now())
        """,
        [Repo.uuid!(wish.id)]
      )

      [row] = Reports.list_public_wishes_for_admin(50)
      assert row.wish_id == wish.id
      assert row.endorsement_count == 1
      assert row.expectation_count == 1
    end
  end

  describe "#817 admin 附议留言聚合 list_wish_endorsements_for_admin" do
    test "按愿望聚合分布与明细（phone/email 仅此处）、token 附议联系方式 nil、无附议不出现" do
      archive = create_archive()
      owner = create_person(archive)
      endorser1 = register_user("817-e1")
      endorser2 = register_user("817-e2")

      Repo.query!(
        "UPDATE users SET phone = '13812340101', email = 'e1@test.com' WHERE id = $1",
        [Repo.uuid!(endorser1.id)]
      )

      {:ok, wish_a} =
        Wishes.create_wish(owner.id, "愿望甲", "public", public_listing_consent: true)

      {:ok, wish_b} =
        Wishes.create_wish(owner.id, "愿望乙", "public", public_listing_consent: true)

      Enum.each([wish_a, wish_b], fn w ->
        Repo.query!(
          "UPDATE flashback_wishes SET listed_at = now(), hidden_at = NULL WHERE id = $1",
          [Repo.uuid!(w.id)]
        )
      end)

      {:ok, _} =
        Wishes.endorse_by_user(endorser1.id, wish_a.id,
          contribution_types: ["venue", "sponsor"],
          message: "场地我出"
        )

      {:ok, _} =
        Wishes.endorse_by_user(endorser2.id, wish_a.id,
          contribution_types: ["venue"],
          message: nil
        )

      # token 附议（user_id nil）直插资源层；愿望乙只此一条 → 乙排甲前（乙更新）
      Cgc2046.Flashback.WishEndorsement
      |> Ash.Changeset.for_create(:create, %{
        wish_id: wish_b.id,
        person_id: owner.id,
        contribution_types: ["organize"],
        message: "老 token 附议"
      })
      |> Ash.create!(authorize?: false)

      # 无附议愿望
      {:ok, _lonely} =
        Wishes.create_wish(owner.id, "没人附议", "public", public_listing_consent: true)

      rows = Reports.list_wish_endorsements_for_admin(50)
      assert length(rows) == 2
      # 最新附议在前：乙（后插入）→ 甲
      [row_b, row_a] = rows
      assert row_a.wish_id == wish_a.id
      assert row_b.wish_id == wish_b.id

      assert row_a.endorsement_count == 2

      assert row_a.contribution_distribution == [
               %{type: "venue", count: 2},
               %{type: "sponsor", count: 1}
             ]

      [d1, d2] = row_a.endorsements
      assert d1.contribution_types == ["venue", "sponsor"]
      assert d1.message == "场地我出"
      assert d1.endorser_phone == "13812340101"
      assert d1.endorser_email == "e1@test.com"
      # d2 是正常登录附议者：无手机号、email 取登录账号值
      assert d2.endorser_phone == nil and is_binary(d2.endorser_email)

      # token 附议（user_id nil）联系方式 nil，不回退档案字段
      [token_detail] = row_b.endorsements
      assert token_detail.message == "老 token 附议"
      assert token_detail.endorser_phone == nil and token_detail.endorser_email == nil
    end

    test "软删愿望的附议不进聚合" do
      archive = create_archive()
      owner = create_person(archive)
      endorser = register_user("817-e-del")

      {:ok, wish} =
        Wishes.create_wish(owner.id, "将被删除", "public", public_listing_consent: true)

      Repo.query!(
        "UPDATE flashback_wishes SET listed_at = now(), hidden_at = NULL WHERE id = $1",
        [Repo.uuid!(wish.id)]
      )

      {:ok, _} = Wishes.endorse_by_user(endorser.id, wish.id, contribution_types: ["other"])

      Repo.query!("UPDATE flashback_wishes SET deleted_at = now() WHERE id = $1", [
        Repo.uuid!(wish.id)
      ])

      assert Reports.list_wish_endorsements_for_admin(50) == []
    end
  end

  describe "#817 admin 放行挂树 approve_wish_listing" do
    test "待审愿望（有授权）→ 挂树 + 清 hidden + 不动信用 + 进公开树" do
      archive = create_archive()
      author = create_person(archive)
      author_user = register_user("817-approve-author")
      bind_person_to_user(author.id, author_user.id)

      Repo.query!(
        "UPDATE users SET wishes_review_required_at = now() WHERE id = $1",
        [Repo.uuid!(author_user.id)]
      )

      {:ok, wish} =
        Wishes.create_wish(author.id, "待审放行", "public", public_listing_consent: true)

      assert is_nil(wish.listed_at) and wish.hidden_at != nil
      admin = make_admin_user("817-approve-admin")

      {:ok, approved} = Reports.approve_wish_listing(wish.id, admin.id)
      assert approved.listed_at != nil
      assert approved.hidden_at == nil

      # 放行后进公开树
      assert Enum.any?(Wishes.list_public_listed(), &(&1.id == wish.id))

      # 信用字段不动（放行 ≠ 信用解除）
      %{rows: [[credit]]} =
        Repo.query!("SELECT wishes_review_required_at FROM users WHERE id = $1", [
          Repo.uuid!(author_user.id)
        ])

      assert credit != nil
    end

    test "无授权证据（consent 从未给过）→ 拒绝且不挂树（授权不扩大红线）" do
      archive = create_archive()
      owner = create_person(archive)
      admin = make_admin_user("817-noconsent-admin")

      {:ok, wish} =
        Wishes.create_wish(owner.id, "从未授权", "public", public_listing_consent: false)

      # admin 曾直接 hide 未授权愿望（无 UI 入口的长尾形态：listed nil + hidden 置位）
      {:ok, _} = Reports.set_wish_hidden(wish.id, admin.id, true)

      assert {:error, %{code: "flashback_wish_listing_not_authorized"}} =
               Reports.approve_wish_listing(wish.id, admin.id)

      reloaded = Ash.get!(Cgc2046.Flashback.Wish, wish.id, authorize?: false)

      assert is_nil(reloaded.listed_at)
      refute Enum.any?(Wishes.list_public_listed(), &(&1.id == wish.id))
    end

    test "已挂架愿望幂等返回（并发双击兜底）；private 愿望拒绝" do
      archive = create_archive()
      owner = create_person(archive)
      admin = make_admin_user("817-idem-admin")

      listed = create_listed_wish(owner, "已挂树")
      {:ok, again} = Reports.approve_wish_listing(listed.id, admin.id)
      assert again.listed_at == listed.listed_at

      {:ok, private_wish} = Wishes.create_wish(owner.id, "悄悄话", "private")

      assert {:error, %{code: "flashback_wish_listing_not_authorized"}} =
               Reports.approve_wish_listing(private_wish.id, admin.id)
    end

    test "非 admin 调用被拒" do
      archive = create_archive()
      owner = create_person(archive)
      author = create_person(archive, %{full_name: "赵小刚", surname: "赵"})
      author_user = register_user("817-approve-degraded")
      bind_person_to_user(author.id, author_user.id)

      Repo.query!(
        "UPDATE users SET wishes_review_required_at = now() WHERE id = $1",
        [Repo.uuid!(author_user.id)]
      )

      {:ok, wish} =
        Wishes.create_wish(author.id, "待审但非 admin 放行", "public", public_listing_consent: true)

      passerby = register_user("817-passerby")

      assert {:error, %{code: "flashback_auth_required"}} =
               Reports.approve_wish_listing(wish.id, passerby.id)

      reloaded = Ash.get!(Cgc2046.Flashback.Wish, wish.id, authorize?: false)

      assert is_nil(reloaded.listed_at)
    end
  end
end
