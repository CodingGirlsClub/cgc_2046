defmodule Cgc2046.Flashback.OutreachTest do
  @moduledoc """
  U8/KTD6 —— 批量触达与退订（R23 批量发送 / R24 记录侧 / R30 退订）。

  覆盖：pilot 规模批量入队幂等（344 人重跑零新增）、错峰限速、Oban args 无
  明文 token（KTD2）、email/sms 双通道退订抑制、worker 端 token 铸造（生成→
  渲染→发送→只落 hash）、失败→重试→sent 状态机推进、退订者二次触达跳过、
  匿名化后 outreach 无个人字段、退订端点三态、admin mutation 门控。

  沙箱纪律：SendCloud 短信走 Req.Test stub（未 stub 即 raise，绝不外呼）；
  邮件走 Swoosh.Adapters.Test（进程 mailbox 断言）；:flashback_sms env 的
  fail-closed 用例在 setup/on_exit 恢复原值。
  """

  use Cgc2046Web.ConnCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  import Ecto.Query

  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Outreach, Person, Token}
  alias Cgc2046.Flashback.Outreach.{Dispatch, Emails}
  alias Cgc2046.Flashback.Workers.OutreachWorker
  alias Cgc2046.Repo

  @moduletag :capture_log

  @email "wangxiaoming@example.com"
  @phone "13900000001"

  setup do
    Req.Test.stub(Cgc2046.SmsSendCloudStub, fn conn ->
      Req.Test.json(conn, %{"result" => true})
    end)

    on_exit(fn ->
      Application.put_env(:cgc_2046, :flashback_sms, template_id: "test-flashback-sms-template")
    end)

    :ok
  end

  # ── 批量入队（R23） ───────────────────────────────────────────────────

  describe "pilot 规模批量入队（344 人幂等 + 错峰限速 + args 纪律）" do
    test "344 人入队：全部建行 + job 错峰递增 + args 无明文 token；重跑零新增" do
      archive = create_archive()
      insert_people(archive, 344)
      batch = "archive-" <> archive.key

      assert {:ok, %{queued: 344, skipped: 0}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect")

      assert outreach_count(%{batch: batch, channel: :email}) == 344

      jobs = enqueued_outreach_jobs(batch)
      assert length(jobs) == 344

      # 错峰限速（KTD6 可配速率）：默认 120/分钟 → 相邻 job 间隔 ≥ 500ms、递增
      schedulings = jobs |> Enum.map(& &1.scheduled_at) |> Enum.sort(DateTime)

      diffs =
        Enum.zip(schedulings, tl(schedulings))
        |> Enum.map(fn {a, b} -> DateTime.diff(b, a, :millisecond) end)

      assert diffs != [] and Enum.all?(diffs, &(&1 >= 500))

      # KTD2：args 只带 person/channel/batch/template——无 PII、无明文 token
      for job <- jobs do
        assert Map.keys(job.args) |> MapSet.new() ==
                 MapSet.new(["person_id", "channel", "batch", "template"])

        refute inspect(job.args) =~ "token"
      end

      # 幂等重跑（断点续发核心语义）：unique_send DB 闸 → 零新增行、零新增 job
      assert {:ok, %{queued: 0, skipped: 344}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect")

      assert outreach_count(%{batch: batch, channel: :email}) == 344
      assert length(enqueued_outreach_jobs(batch)) == 344
    end

    test "未知模板/场次 → 显式业务错误码" do
      archive = create_archive()

      assert {:error, %{code: "flashback_archive_not_found"}} =
               Dispatch.enqueue_for_archive("no-such-archive", "reconnect")

      assert {:error, %{code: "flashback_invalid_input"}} =
               Dispatch.enqueue_for_archive(archive.key, "bogus_template")
    end
  end

  # ── 通道选择（R11：全部/仅邮件/仅短信三档） ─────────────────────────

  describe "通道选择（R11 三档）" do
    # 名册：2 email-only + 1 phone-only + 1 双通道
    defp mixed_roster(archive) do
      email_only_a = create_person(archive, full_name: "邮甲", phone: nil)

      email_only_b =
        create_person(archive, full_name: "邮乙", email: "youyi@example.com", phone: nil)

      phone_only = create_person(archive, full_name: "短丙", email: nil)
      both = create_person(archive, full_name: "双丁")

      {email_only_a, email_only_b, phone_only, both}
    end

    test "仅邮件：email 可达者全走 email 通道；phone-only 零行" do
      archive = create_archive()
      {email_a, email_b, phone_only, _both} = mixed_roster(archive)
      batch = "archive-" <> archive.key

      assert {:ok, %{queued: 3, skipped: 1}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect", :email)

      assert outreach_count(%{batch: batch, channel: :email}) == 3
      assert outreach_count(%{person_id: phone_only.id}) == 0
      assert %{channel: :email} = outreach_row!(email_a.id, :email)
      assert %{channel: :email} = outreach_row!(email_b.id, :email)
    end

    test "全部：双通道者走 email（优先）、phone-only 走 sms（现行为锚点）" do
      archive = create_archive()
      {_ea, _eb, phone_only, both} = mixed_roster(archive)
      batch = "archive-" <> archive.key

      assert {:ok, %{queued: 4, skipped: 0}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect", :all)

      assert outreach_count(%{batch: batch, channel: :email}) == 3
      assert outreach_count(%{batch: batch, channel: :sms}) == 1
      assert %{channel: :email} = outreach_row!(both.id, :email)
      assert %{channel: :sms} = outreach_row!(phone_only.id, :sms)
    end

    test "仅短信：sms 可达者全走 sms 通道；email-only 零行" do
      archive = create_archive()
      {email_a, _eb, _po, _both} = mixed_roster(archive)
      batch = "archive-" <> archive.key

      assert {:ok, %{queued: 2, skipped: 2}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect", :sms)

      assert outreach_count(%{batch: batch, channel: :sms}) == 2
      assert outreach_count(%{person_id: email_a.id}) == 0
    end

    test "短信未配置：仅短信全跳过；全部退化为纯邮件腿（fail-closed 回归）" do
      Application.put_env(:cgc_2046, :flashback_sms, template_id: nil)

      archive = create_archive()
      {_ea, _eb, _po, _both} = mixed_roster(archive)
      batch = "archive-" <> archive.key

      assert {:ok, %{queued: 0, skipped: 4}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect", :sms)

      assert {:ok, %{queued: 3, skipped: 1}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect", :all)

      assert outreach_count(%{batch: batch, channel: :sms}) == 0
      assert outreach_count(%{batch: batch, channel: :email}) == 3
    end

    test "非法通道 → flashback_invalid_input" do
      archive = create_archive()

      assert {:error, %{code: "flashback_invalid_input"}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect", :fax)
    end

    test "GraphQL：channel 参数传导到入队（admin token）" do
      archive = create_archive()
      {_ea, _eb, phone_only, _both} = mixed_roster(archive)
      batch = "archive-" <> archive.key
      admin = register_and_sign_in("outreach-channel", :admin)

      res =
        post_graphql(
          """
          mutation {
            flashbackAdminSendOutreach(archiveKey: "#{archive.key}", template: "reconnect", channel: "sms") {
              queued skipped
            }
          }
          """,
          admin.token
        )

      assert %{"queued" => 2, "skipped" => 2} = res["data"]["flashbackAdminSendOutreach"]
      assert outreach_count(%{batch: batch, channel: :sms}) == 2
      assert outreach_count(%{person_id: phone_only.id, channel: :sms}) == 1
    end
  end

  # ── 退订（R30：按人抑制双通道） ───────────────────────────────────────

  describe "退订抑制（email 与 sms 双通道均不再入队）" do
    test "退订者：两条通道都不入队；未退订者照常入队" do
      archive = create_archive()
      unsubscribed = create_person(archive, full_name: "李小红", phone: @phone)
      normal = create_person(archive)

      :ok = Dispatch.unsubscribe_person(unsubscribed.id)

      assert {:ok, %{queued: 1, skipped: 1}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect")

      # 退订者（email+phone 双通道可用）零行；未退订者一行 email
      assert outreach_count(%{person_id: unsubscribed.id}) == 0
      assert outreach_count(%{person_id: normal.id, channel: :email}) == 1
    end

    test "退订者被二次触达跳过（worker 执行前退订 → 静默不发）" do
      archive = create_archive()
      person = create_person(archive)

      {:ok, %{queued: 1}} = Dispatch.enqueue_for_archive(archive.key, "reconnect")
      :ok = Dispatch.unsubscribe_person(person.id)

      assert [%{args: args}] = enqueued_outreach_jobs("archive-" <> archive.key)
      assert :ok = perform_job(OutreachWorker, args)

      # 无邮件、无 token、行停在 queued（发送统计分母自动剔除，KTD10）
      refute_receive {:email, _}, 50
      assert token_count(person.id) == 0
      assert outreach_row!(person.id, :email).status == :queued
    end
  end

  # ── 单人重发（R2/R5：拒绝语义 + resend-* 批次；KD8 不频控） ──────────

  describe "单人重发（resend_for_person）" do
    test "未认领可达者：重发成功落 resend-* 批次，通道按可达性" do
      archive = create_archive()
      person = create_person(archive)

      assert {:ok, %{queued: 1, skipped: 0, batch: batch}} =
               Dispatch.resend_for_person(person.id, "reconnect")

      assert String.starts_with?(batch, "resend-")
      assert %{status: :queued} = outreach_row!(person.id, :email)

      # KD8 不频控：独立第二次重发照常入队（新批次）
      assert {:ok, %{queued: 1, batch: batch2}} =
               Dispatch.resend_for_person(person.id, "reconnect")

      refute batch2 == batch
      assert outreach_count(%{person_id: person.id}) == 2
    end

    test "重发通道选择：仅短信档走 sms 通道" do
      archive = create_archive()
      person = create_person(archive)

      assert {:ok, %{queued: 1}} = Dispatch.resend_for_person(person.id, "reconnect", :sms)

      assert %{channel: :sms} = outreach_row!(person.id, :sms)
    end

    test "已认领者 → flashback_person_claimed，零新增行" do
      archive = create_archive()
      person = create_person(archive)
      claim_person(person)

      assert {:error, %{code: "flashback_person_claimed"}} =
               Dispatch.resend_for_person(person.id, "reconnect")

      assert outreach_count(%{person_id: person.id}) == 0
    end

    test "已退订者 → flashback_person_unsubscribed，零新增行" do
      archive = create_archive()
      person = create_person(archive)
      :ok = Dispatch.unsubscribe_person(person.id)

      assert {:error, %{code: "flashback_person_unsubscribed"}} =
               Dispatch.resend_for_person(person.id, "reconnect")

      assert outreach_count(%{person_id: person.id}) == 0
    end

    test "已删除者 → flashback_already_deleted，零新增行" do
      archive = create_archive()
      person = create_person(archive)
      mark_deleted(person)

      assert {:error, %{code: "flashback_already_deleted"}} =
               Dispatch.resend_for_person(person.id, "reconnect")

      assert outreach_count(%{person_id: person.id}) == 0
    end

    test "无可用通道者（字段全空）→ ok 零入队" do
      archive = create_archive()
      person = create_person(archive, email: nil, phone: nil)

      assert {:ok, %{queued: 0, skipped: 1}} =
               Dispatch.resend_for_person(person.id, "reconnect")
    end

    test "未知 person / 未知模板 → 显式业务错误" do
      assert {:error, %{code: "flashback_person_not_found"}} =
               Dispatch.resend_for_person(Ecto.UUID.generate(), "reconnect")

      archive = create_archive()
      person = create_person(archive)

      assert {:error, %{code: "flashback_invalid_input"}} =
               Dispatch.resend_for_person(person.id, "bogus_template")
    end
  end

  # ── worker：token 铸造与双通道发送（KTD2/KTD6） ───────────────────────

  describe "outreach worker（token 在 worker 内铸造，明文只落邮件体）" do
    test "email 腿：发送成功 → 落 token_hash + 行 sent；邮件含专属链接与页脚退订链接" do
      archive = create_archive()
      person = create_person(archive)

      args = enqueue_one(person, "reconnect")

      assert {:ok, :email} = perform_job(OutreachWorker, args)

      # KTD2：hash 落库、明文只出现在邮件体（enter_url）
      assert token_count(person.id) == 1
      row = outreach_row!(person.id, :email)
      assert row.status == :sent
      assert row.sent_at

      assert_receive {:email, email}, 1_000
      {_name, address} = List.first(email.to)
      assert address == @email
      # 称呼用全名；主题逐字引学员原话「刚刚一闪念间」
      assert email.subject =~ "刚刚一闪念间"
      assert email.text_body =~ "你好，王小明："
      assert email.html_body =~ "你好，王小明："
      # 本人场次日期个性化（create_archive occurred_on = 2014-01-11）
      assert email.html_body =~ "你也在 2014 年 1 月推开过这扇窗"
      assert email.text_body =~ "你也在 2014 年 1 月推开过这扇窗"
      # 逐字引文（与截图并排可对照）+ 原图 + 小程序搜索引导
      assert email.html_body =~ "weibo-screenshot.png"
      assert email.html_body =~ "但刚刚一闪念间想起来曾经参加的这个活动"
      assert email.text_body =~ "但刚刚一闪念间想起来曾经参加的这个活动"
      assert email.html_body =~ "搜索「程序媛汇」或「程序媛汇2046」"
      assert email.text_body =~ "搜索「程序媛汇」或「程序媛汇2046」"
      assert email.html_body =~ "/zh-CN/flashback/enter?token="
      assert email.text_body =~ "/zh-CN/flashback/enter?token="
      # R30：页脚退订链接（HTML 与纯文本都带）
      assert email.html_body =~ "/api/flashback/unsubscribe?t="
      assert email.text_body =~ "/api/flashback/unsubscribe?t="
    end

    test "email 腿：场次日期缺失 → 文案降级「那年」，不因 nil 崩发送" do
      archive =
        Flashback.EventArchive
        |> Ash.Changeset.for_create(:create, %{
          key: "no-date-#{System.unique_integer([:positive])}",
          name: "Rails Girls Shanghai",
          city: "上海"
        })
        |> Ash.create!(authorize?: false)

      person = create_person(archive)
      args = enqueue_one(person, "reconnect")

      assert {:ok, :email} = perform_job(OutreachWorker, args)

      assert_receive {:email, email}, 1_000
      assert email.html_body =~ "你也在 那年推开过这扇窗"
      assert email.text_body =~ "你也在 那年推开过这扇窗"
      refute email.html_body =~ "2014 年 1 月"
    end

    test "sms 腿：phone-only 档案 → SendCloud 模板短信带 year + brand 变量" do
      archive = create_archive()
      person = create_person(archive, email: nil, phone: @phone)

      test_pid = self()

      Req.Test.stub(Cgc2046.SmsSendCloudStub, fn conn ->
        vars = conn.body_params["vars"] |> Jason.decode!()
        send(test_pid, {:sms, conn.body_params["templateId"], vars})
        Req.Test.json(conn, %{"result" => true})
      end)

      args = enqueue_one(person, "reconnect")

      assert {:ok, :sms} = perform_job(OutreachWorker, args)

      assert_receive {:sms, template_id, vars}
      assert template_id == "test-flashback-sms-template"

      # 942116 行业通知模板：正文「还记得%year%年报名过 %brand% 吗？……回T退订」
      assert vars == %{"year" => "2014", "brand" => "Rails Girls"}
      # sms 腿无链接：不铸 token（身份凭证表零垃圾行）
      assert token_count(person.id) == 0
      assert outreach_row!(person.id, :sms).status == :sent
    end

    test "sms 腿：场次日期缺失或未知品牌名 → skip 不发错文案" do
      no_date =
        Flashback.EventArchive
        |> Ash.Changeset.for_create(:create, %{
          key: "no-date-sms-#{System.unique_integer([:positive])}",
          name: "Rails Girls Beijing",
          city: "北京"
        })
        |> Ash.create!(authorize?: false)

      person = create_person(no_date, email: nil, phone: @phone)
      args = enqueue_one(person, "reconnect")

      assert :ok = perform_job(OutreachWorker, args)
      # 建行后 skip 落 failed 终态（批次历史不显示「排队中」永不收敛）
      assert outreach_row!(person.id, :sms).status == :failed
      assert outreach_row!(person.id, :sms).detail =~ "sms_vars_missing"

      unknown_brand =
        Flashback.EventArchive
        |> Ash.Changeset.for_create(:create, %{
          key: "unknown-brand-#{System.unique_integer([:positive])}",
          name: "某黑客松 2026",
          city: "北京",
          occurred_on: ~D[2026-10-18]
        })
        |> Ash.create!(authorize?: false)

      person2 = create_person(unknown_brand, email: nil, phone: @phone)
      args2 = enqueue_one(person2, "reconnect")

      assert :ok = perform_job(OutreachWorker, args2)
      assert outreach_row!(person2.id, :sms).status == :failed
    end

    test "sms 腿：pilot 双品牌场次名 → 首段主品牌 Rails Girls（非 GCD）" do
      pilot =
        Flashback.EventArchive
        |> Ash.Changeset.for_create(:create, %{
          key: "pilot-dual-#{System.unique_integer([:positive])}",
          name: "Rails Girls / Girls Coding Day 北京",
          city: "北京",
          occurred_on: ~D[2014-01-11]
        })
        |> Ash.create!(authorize?: false)

      person = create_person(pilot, email: nil, phone: @phone)

      test_pid = self()

      Req.Test.stub(Cgc2046.SmsSendCloudStub, fn conn ->
        vars = conn.body_params["vars"] |> Jason.decode!()
        send(test_pid, {:sms, conn.body_params["templateId"], vars})
        Req.Test.json(conn, %{"result" => true})
      end)

      args = enqueue_one(person, "reconnect")

      assert {:ok, :sms} = perform_job(OutreachWorker, args)

      assert_receive {:sms, _template_id, vars}
      # 2014 pilot 是 Rails Girls 场——含双品牌词时按首段判主品牌
      assert vars == %{"year" => "2014", "brand" => "Rails Girls"}
    end

    test "发送失败 → 行 failed + Oban 重试；配置就绪后重试成功推进到 sent" do
      archive = create_archive()
      person = create_person(archive, email: nil, phone: @phone)

      Req.Test.stub(Cgc2046.SmsSendCloudStub, fn conn ->
        Req.Test.json(conn, %{"result" => false, "message" => "template rejected"})
      end)

      args = enqueue_one(person, "reconnect")

      assert {:error, _} = perform_job(OutreachWorker, args)
      row = outreach_row!(person.id, :sms)
      assert row.status == :failed
      assert row.detail =~ "send_cloud_sms"

      # 配置就绪（渠道恢复）后重试：failed → sent（断点续发的行级语义）
      Req.Test.stub(Cgc2046.SmsSendCloudStub, fn conn ->
        Req.Test.json(conn, %{"result" => true})
      end)

      assert {:ok, :sms} = perform_job(OutreachWorker, args)
      assert outreach_row!(person.id, :sms).status == :sent
    end

    test "重复执行已 sent 的 job → 幂等跳过，不重铸 token 不重发" do
      archive = create_archive()
      person = create_person(archive)
      args = enqueue_one(person, "reconnect")

      assert {:ok, :email} = perform_job(OutreachWorker, args)
      assert_receive {:email, _}, 1_000

      assert :ok = perform_job(OutreachWorker, args)
      refute_receive {:email, _}, 50
      assert token_count(person.id) == 1
    end
  end

  # ── 短信 fail-closed（KTD6：模板未申请不外呼） ────────────────────────

  describe "短信模板 fail-closed" do
    test "flashback_sms 未配置 → phone-only 档案被入队面抑制；已有行重试返回错误" do
      Application.put_env(:cgc_2046, :flashback_sms, template_id: nil)

      archive = create_archive()
      person = create_person(archive, email: nil, phone: @phone)

      assert {:ok, %{queued: 0, skipped: 1}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect")

      # 邮件腿不受影响（email 档案照常入队）
      other = create_person(archive, full_name: "张大三", email: "z@e.com", phone: "13900000099")
      assert {:ok, %{queued: 1}} = Dispatch.enqueue_for_archive(archive.key, "reconnect")
      assert outreach_count(%{person_id: other.id, channel: :email}) == 1

      # 已入队的 sms 行在配置缺失期重试 → 显式错误（不静默吞配置事故）。
      # sms 未配置时入队面已抑制该人——手动落一行 queued 模拟「配置在入队后
      # 被撤下」的竞态窗口，worker 的 fail-closed 是第二道闸。
      row =
        Outreach
        |> Ash.Changeset.for_create(:create, %{
          person_id: person.id,
          channel: :sms,
          template: "reconnect",
          batch: "manual-race"
        })
        |> Ash.create!(authorize?: false)

      assert {:error, :sms_not_configured} =
               perform_job(OutreachWorker, %{
                 "person_id" => person.id,
                 "channel" => "sms",
                 "batch" => "manual-race",
                 "template" => "reconnect"
               })

      assert Repo.reload!(row).status == :failed
    end
  end

  # ── 匿名化（R30「从第一封邮件起生效」；U10 删除级联消费的能力面） ────

  describe "outreach 个人字段匿名化" do
    test "匿名化后：person 通道字段清空 + outreach 行保留（聚合统计）+ 再入队被抑制" do
      archive = create_archive()
      person = create_person(archive)
      {:ok, %{queued: 1}} = Dispatch.enqueue_for_archive(archive.key, "reconnect")

      assert :ok = Dispatch.anonymize_person(person.id)

      anonymized = Repo.reload!(person)
      assert anonymized.full_name == "已删除档案"
      assert anonymized.phone == nil and anonymized.email == nil
      assert anonymized.city == nil and anonymized.occupation_then == nil

      # outreach 行保留（发送状态聚合，U11 分母）；经 person_id 回查零 PII
      assert outreach_count(%{person_id: person.id}) == 1

      # 新批次：无可用通道 → 不再触达（删除请求后 outreach 面无个人字段可言）
      assert {:ok, %{queued: 0, skipped: 1}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect")
    end
  end

  # ── 退订端点（R30 一键退订） ─────────────────────────────────────────

  describe "退订端点 GET /api/flashback/unsubscribe" do
    test "有效 token：置位 + 200 已退订页；重复点击幂等显示已退订" do
      archive = create_archive()
      person = create_person(archive)
      token = Dispatch.unsubscribe_token(person.id)

      conn = get(build_conn(), "/api/flashback/unsubscribe", %{"t" => token})

      assert html_response(conn, 200) =~ "已为你退订"
      assert Dispatch.unsubscribed?(person.id)

      again = get(build_conn(), "/api/flashback/unsubscribe", %{"t" => token})
      assert html_response(again, 200) =~ "你已退订"
    end

    test "无效/缺失 token → 404（不区分原因）" do
      assert html_response(
               get(build_conn(), "/api/flashback/unsubscribe", %{"t" => "garbage"}),
               404
             ) =~
               "无效"

      assert html_response(get(build_conn(), "/api/flashback/unsubscribe"), 404) =~ "无效"
    end

    test "退订后入队面立即生效（端点置位 → 双通道抑制）" do
      archive = create_archive()
      person = create_person(archive)

      get(build_conn(), "/api/flashback/unsubscribe", %{
        "t" => Dispatch.unsubscribe_token(person.id)
      })

      assert {:ok, %{queued: 0, skipped: 1}} =
               Dispatch.enqueue_for_archive(archive.key, "reconnect")
    end
  end

  # ── admin mutation（R23 运营入口；非管理员被拒——变异验证钉住点） ────

  describe "flashbackAdminSendOutreach（PlatformAdmin gate）" do
    test "非管理员被拒；平台管理员入队成功返回计数" do
      archive = create_archive()
      insert_people(archive, 2)

      # 未登录 → unauthorized
      res = post_graphql(send_outreach_mutation(archive.key), nil)
      assert [%{"code" => "unauthorized"}] = res["errors"]

      # 普通用户 → forbidden
      user = register_and_sign_in("outreach-plain")
      res = post_graphql(send_outreach_mutation(archive.key), user.token)
      assert [%{"code" => "forbidden"}] = res["errors"]
      assert outreach_count(%{batch: "archive-" <> archive.key}) == 0

      # 平台管理员 → 入队
      admin = register_and_sign_in("outreach-admin", :admin)
      res = post_graphql(send_outreach_mutation(archive.key), admin.token)

      assert %{"queued" => 2, "skipped" => 0} = res["data"]["flashbackAdminSendOutreach"]
      assert outreach_count(%{batch: "archive-" <> archive.key}) == 2
    end
  end

  # ── 邮件模板纪律（R30：页脚退订链接不可漏） ─────────────────────────

  describe "邮件模板（页脚退订链接硬约束）" do
    test "reconnect 模板的 HTML 与纯文本均含退订链接" do
      email =
        Emails.reconnect(
          @email,
          "王小明",
          ~D[2014-01-11],
          "Rails Girls Beijing",
          "https://x/enter?token=abc",
          "https://x/unsub?t=d",
          "https://x/flashback/weibo-screenshot.png"
        )

      assert email.html_body =~ "https://x/unsub?t=d"
      assert email.text_body =~ "https://x/unsub?t=d"
      # 日期个性化 + 逐字引文（与截图并排可对照）+ 页脚按本人场次派生
      assert email.html_body =~ "你也在 2014 年 1 月推开过这扇窗"
      assert email.html_body =~ "你在 2014 年参加过 Rails Girls Beijing 的活动"
      # 中文结尾场次名：名前不加空格（「…北京 的活动」不多空格）
      assert email.html_body =~ "但刚刚一闪念间想起来曾经参加的这个活动"
    end

    test "reconnect 模板：occurred_on 为 nil → 「那年」降级，不崩" do
      email =
        Emails.reconnect(@email, nil, nil, nil, "https://x/e", "https://x/u", "https://x/s.png")

      assert email.html_body =~ "你也在 那年推开过这扇窗"
      # 页脚无场次信息 → 历史区间兜底句
      assert email.html_body =~ "你在 2012-2018 年间参加过 Rails Girls / Girls Coding Day 的活动"
      # 无名字 → 模板层兜底「同学」
      assert email.text_body =~ "你好，同学："
    end
  end

  # ── fixtures ─────────────────────────────────────────────────────────

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
          role: :learner,
          participation: :attended,
          phone: @phone,
          email: @email
        },
        Map.new(attrs)
      )

    Person
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :archive_event_id, archive.id))
    |> Ash.create!(authorize?: false)
  end

  # 344 人规模用裸 insert_all（Ash 逐条建 344 次太慢）。裸表无类型信息：uuid
  # 须 dump 成 16 字节 binary、atom 字段落 string（与迁移列型一致）。
  defp insert_people(archive, n) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for i <- 1..n do
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          archive_event_id: Ecto.UUID.dump!(archive.id),
          full_name: "同学#{i}",
          surname: "同",
          city: "北京",
          occupation_then: "student",
          phone: "1390000" <> String.pad_leading(Integer.to_string(10_000 + i), 4, "0"),
          email: "member#{i}@example.com",
          role: "learner",
          participation: "attended",
          inserted_at: now,
          updated_at: now
        }
      end

    {^n, nil} = Repo.insert_all("flashback_people", rows)
    :ok
  end

  defp claim_person(person) do
    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:user_id, Ecto.UUID.generate())
    |> Ash.update!(authorize?: false)
  end

  defp mark_deleted(person) do
    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:deleted_at, DateTime.utc_now())
    |> Ash.update!(authorize?: false)
  end

  defp enqueue_one(person, template, extra \\ %{}) do
    {1, _} = Dispatch.enqueue_persons([person.id], template, "test-batch")
    job = Enum.find(enqueued_outreach_jobs("test-batch"), &(&1.args["person_id"] == person.id))
    Map.merge(job.args, extra)
  end

  defp enqueued_outreach_jobs(batch) do
    from(j in Oban.Job,
      where:
        j.worker == "Cgc2046.Flashback.Workers.OutreachWorker" and
          fragment("args->>'batch' = ?", ^batch),
      select: %{args: j.args, scheduled_at: j.scheduled_at}
    )
    |> Repo.all()
  end

  defp outreach_count(filters) when is_map(filters) do
    Outreach
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(^filters)
    |> Ash.read!(authorize?: false, page: false)
    |> length()
  end

  defp outreach_row!(person_id, channel) do
    Outreach
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person_id and channel == ^channel)
    |> Ash.read_one!(authorize?: false)
  end

  defp token_count(person_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person_id)
    |> Ash.read!(authorize?: false, page: false)
    |> length()
  end

  defp post_graphql(query, token) do
    conn = build_conn() |> put_req_header("content-type", "application/json")

    conn =
      if token,
        do: put_req_header(conn, "authorization", "Bearer #{token}"),
        else: conn

    conn |> post("/api/graphql", %{"query" => query}) |> json_response(200)
  end

  defp send_outreach_mutation(archive_key) do
    """
    mutation {
      flashbackAdminSendOutreach(archiveKey: "#{archive_key}", template: "reconnect") {
        queued skipped
      }
    }
    """
  end

  # signIn 走 httpOnly cookie（cgc_token）；Bearer 值从 resp_cookies 提取
  # （graphql_platform_admin_readonly_test 同款）。
  defp register_and_sign_in(name, kind \\ :plain) do
    alias Cgc2046.AccountsFixtures, as: Fixtures

    user =
      if kind == :admin,
        do: Fixtures.platform_admin("outreach-#{name}"),
        else: Fixtures.register_user("outreach-#{name}")

    mutation = """
    mutation { signIn(login: "#{user.email}", password: "#{Fixtures.password()}") { id } }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)

    %{user: user, token: conn.resp_cookies["cgc_token"].value}
  end
end
