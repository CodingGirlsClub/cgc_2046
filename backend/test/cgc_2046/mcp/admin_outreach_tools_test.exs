defmodule Cgc2046.Mcp.AdminOutreachToolsTest do
  @moduledoc """
  闪念间触达两工具（R1/R2/R5/R6）：门控 fail-closed、两段式确认（R4 摘要
  口径 / R5 拒绝表第一段快速失败 / R6 短信腿 fail-closed）、治理留痕
  （AdminActionLog flashback_outreach_send/resend）。
  """

  use Cgc2046.DataCase, async: false

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Flashback.Outreach.Dispatch

  alias Cgc2046.Mcp.Tools.{AdminResendFlashbackOutreach, AdminSendFlashbackOutreach}

  require Ash.Query

  setup do
    Req.Test.stub(Cgc2046.SmsSendCloudStub, fn conn ->
      Req.Test.json(conn, %{"result" => true})
    end)

    on_exit(fn ->
      Application.put_env(:cgc_2046, :flashback_sms, template_id: "test-flashback-sms-template")
    end)

    :ok
  end

  defp create_archive do
    Cgc2046.Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "outreach-tools-#{System.unique_integer([:positive])}",
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
          participation: :attended,
          email: "w@example.com",
          phone: "13900000001"
        },
        overrides
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp admin, do: Fixtures.platform_admin("outreach-tool-admin")

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp run_ok(tool, params, user) do
    {:reply, _, _} = reply = tool.execute(params, Frame.new(current_user: user))
    {:ok, decode(reply)}
  end

  defp run_error(tool, params, user) do
    {:error, %Anubis.MCP.Error{message: msg}, _} =
      tool.execute(params, Frame.new(current_user: user))

    msg
  end

  defp outreach_count(person_id) do
    Cgc2046.Flashback.Outreach
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person_id)
    |> Ash.read!(authorize?: false, page: false)
    |> length()
  end

  defp admin_action_count(action) do
    AdminActionLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(action == ^action)
    |> Ash.read!(authorize?: false, page: false)
    |> length()
  end

  describe "门控（fail-closed）" do
    test "无 MCP 身份 → unauthenticated；非平台管理员 → forbidden" do
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AdminSendFlashbackOutreach.execute(%{}, Frame.new())

      assert msg =~ "unauthenticated"

      member = Fixtures.register_user("outreach-member")

      assert {:error, %Anubis.MCP.Error{message: msg2}, _} =
               AdminSendFlashbackOutreach.execute(
                 %{"archive_key" => "x", "template" => "reconnect"},
                 Frame.new(current_user: member)
               )

      assert msg2 =~ "forbidden"

      assert {:error, %Anubis.MCP.Error{message: msg3}, _} =
               AdminResendFlashbackOutreach.execute(
                 %{"person_id" => Ecto.UUID.generate(), "template" => "reconnect"},
                 Frame.new(current_user: member)
               )

      assert msg3 =~ "forbidden"
    end
  end

  describe "admin_send_flashback_outreach（两段式）" do
    test "第一段摘要含 R4 全项；确认段入队 + 治理留痕" do
      archive = create_archive()
      create_person(archive, %{email: "a@example.com", phone: nil, full_name: "邮甲"})
      create_person(archive, %{email: nil, phone: "13900000002", full_name: "短丙"})
      create_person(archive, %{full_name: "双丁"})
      unsubscribed = create_person(archive, %{full_name: "退订戊"})
      :ok = Dispatch.unsubscribe_person(unsubscribed.id)

      actor = admin()

      {:ok, pending} =
        run_ok(
          AdminSendFlashbackOutreach,
          %{"archive_key" => archive.key, "template" => "reconnect"},
          actor
        )

      assert pending["status"] == "needs_confirmation"
      summary = pending["summary"]
      assert summary =~ archive.key
      assert summary =~ "reconnect"
      assert summary =~ "全部（email 优先/phone 兜底）"
      assert summary =~ "退订剔除 1"
      # 三档分布：仅邮件 1 / 仅短信 1 / 双通道 1（R4）
      assert summary =~ "仅邮件 1 / 仅短信 1 / 双通道 1"

      {:ok, confirmed} =
        AdminSendFlashbackOutreach.execute_confirmed(actor, %{
          "archive_key" => archive.key,
          "template" => "reconnect",
          "channel" => "all"
        })

      assert (confirmed[:queued] || confirmed["queued"]) == 3
      assert (confirmed[:skipped] || confirmed["skipped"]) == 1
      assert admin_action_count(:flashback_outreach_send) == 1
    end

    test "未知场次 / 未知模板 / 非法通道 → 快速失败不建 pending" do
      actor = admin()
      archive = create_archive()

      assert run_error(
               AdminSendFlashbackOutreach,
               %{"archive_key" => "no-such", "template" => "reconnect"},
               actor
             ) =~ "flashback_archive_not_found"

      assert run_error(
               AdminSendFlashbackOutreach,
               %{"archive_key" => archive.key, "template" => "bogus"},
               actor
             ) =~ "flashback_invalid_input"

      assert run_error(
               AdminSendFlashbackOutreach,
               %{"archive_key" => archive.key, "template" => "reconnect", "channel" => "fax"},
               actor
             ) =~ "flashback_invalid_input"
    end

    test "短信未配置：摘要标示；确认仅短信被拒（R6 fail-closed）" do
      Application.put_env(:cgc_2046, :flashback_sms, template_id: nil)
      archive = create_archive()
      create_person(archive)
      actor = admin()

      {:ok, pending} =
        run_ok(
          AdminSendFlashbackOutreach,
          %{"archive_key" => archive.key, "template" => "reconnect", "channel" => "sms"},
          actor
        )

      assert pending["summary"] =~ "短信腿未配置"

      # R6：确认段显式拒绝（execute_confirmed 直返 {:error, message}，
      # Confirmation 分派层负责包 JSON 响应）
      assert {:error, msg} =
               AdminSendFlashbackOutreach.execute_confirmed(actor, %{
                 "archive_key" => archive.key,
                 "template" => "reconnect",
                 "channel" => "sms"
               })

      assert msg =~ "sms channel not configured"

      assert outreach_count(
               hd(
                 Cgc2046.Flashback.Person
                 |> Ash.Query.for_read(:read)
                 |> Ash.read!(authorize?: false, page: false)
               ).id
             ) == 0
    end
  end

  describe "admin_resend_flashback_outreach（两段式）" do
    test "合法目标：pending 摘要含遮罩名；确认段入队 resend 批次 + 留痕" do
      archive = create_archive()
      person = create_person(archive, %{full_name: "欧阳娜娜", surname: "欧"})
      actor = admin()

      {:ok, pending} =
        run_ok(
          AdminResendFlashbackOutreach,
          %{"person_id" => person.id, "template" => "reconnect", "channel" => "email"},
          actor
        )

      assert pending["status"] == "needs_confirmation"
      assert pending["summary"] =~ "欧**"
      assert pending["summary"] =~ "仅邮件"

      {:ok, confirmed} =
        AdminResendFlashbackOutreach.execute_confirmed(actor, %{
          "person_id" => person.id,
          "template" => "reconnect",
          "channel" => "email"
        })

      assert (confirmed[:queued] || confirmed["queued"]) == 1
      batch = confirmed[:batch] || confirmed["batch"]
      assert String.starts_with?(batch, "resend-")
      assert admin_action_count(:flashback_outreach_resend) == 1
    end

    test "R5 拒绝表：已认领/已退订/已删除第一段快速失败，不建 pending" do
      archive = create_archive()
      claimed = create_person(archive, %{full_name: "认甲"})
      unsubscribed = create_person(archive, %{full_name: "退乙"})
      deleted = create_person(archive, %{full_name: "删丙"})

      claimed
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:user_id, Ecto.UUID.generate())
      |> Ash.update!(authorize?: false)

      :ok = Dispatch.unsubscribe_person(unsubscribed.id)

      deleted
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:deleted_at, DateTime.utc_now())
      |> Ash.update!(authorize?: false)

      actor = admin()

      for {person, code} <- [
            {claimed, "flashback_person_claimed"},
            {unsubscribed, "flashback_person_unsubscribed"},
            {deleted, "flashback_already_deleted"}
          ] do
        assert run_error(
                 AdminResendFlashbackOutreach,
                 %{"person_id" => person.id, "template" => "reconnect"},
                 actor
               ) =~ code

        assert outreach_count(person.id) == 0
      end
    end
  end
end
