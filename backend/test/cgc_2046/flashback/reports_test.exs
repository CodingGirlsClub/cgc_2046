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

    wish
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
end
