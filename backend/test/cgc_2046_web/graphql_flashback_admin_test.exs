defmodule Cgc2046Web.GraphqlFlashbackAdminTest do
  @moduledoc """
  U11 看板 GraphQL 面：PlatformAdmin gate——非 admin（未登录/普通用户）被拒。
  变异验证（随附记录）：去掉 with_admin gate（改直接调用）→ forbidden 断言红。
  """
  use Cgc2046Web.ConnCase, async: false

  require Ash.Query

  alias Cgc2046.AccountsFixtures

  @moduletag :capture_log

  @stats_query """
  query { flashbackAdminStats {
    memory { delivered linkOpened: link_opened revealed sentToWall: sent_to_wall intentSubmitted: intent_submitted }
    dream { delivered linkOpened: link_opened revealed sentToWall: sent_to_wall intentSubmitted: intent_submitted }
    overall { delivered }
  } }
  """

  @redemptions_query """
  query { flashbackAdminRedemptions { id status channelNote: channel_note maskedName: masked_name } }
  """

  defp post_graphql(query, user \\ nil, variables \\ nil) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")

    conn =
      if user do
        token = sign_in_token(user)
        put_req_header(conn, "authorization", "Bearer #{token}")
      else
        conn
      end

    payload = %{"query" => query}

    payload =
      if variables,
        do: Map.put(payload, "variables", variables),
        else: payload

    conn |> post("/api/graphql", payload) |> json_response(200)
  end

  defp sign_in_token(user) do
    mutation = """
    mutation { signIn(login: "#{user.email}", password: "#{AccountsFixtures.password()}") { id } }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    conn.resp_cookies["cgc_token"].value
  end

  test "未登录 → forbidden（不泄露数据）" do
    res = post_graphql(@stats_query)
    assert [%{"code" => "unauthorized"}] = res["errors"]

    res = post_graphql(@redemptions_query)
    assert [%{"code" => "unauthorized"}] = res["errors"]
  end

  test "普通用户 → forbidden" do
    user = AccountsFixtures.register_user("fb-admin-plain")

    res = post_graphql(@stats_query, user)
    assert [%{"code" => "forbidden"}] = res["errors"]
  end

  test "platform_admin → 四率与兑换队列可读（空库零值）" do
    admin = AccountsFixtures.platform_admin("fb-admin-admin")

    res = post_graphql(@stats_query, admin)
    stats = res["data"]["flashbackAdminStats"]
    assert stats["overall"]["delivered"] == 0
    assert stats["memory"]["linkOpened"] == 0

    res = post_graphql(@redemptions_query, admin)
    assert res["data"]["flashbackAdminRedemptions"] == []
  end

  # ── 触达运营台查询（R4/R8/R9） ──────────────────────────────────────

  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.Outreach.Dispatch

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
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "outreach-query-#{System.unique_integer([:positive])}",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, overrides \\ %{}) do
    Flashback.Person
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

  @preview_query """
  query($key: String!, $channel: String) {
    flashbackOutreachPreview(archiveKey: $key, channel: $channel) {
      archiveKey: archive_key queued emailOnly: email_only smsOnly: sms_only both
      unsubscribed smsReady: sms_ready
    }
  }
  """

  @batches_query """
  query($key: String!) {
    flashbackOutreachBatches(archiveKey: $key) {
      batch template firstAt: first_at
      email { queued sent failed }
      sms { queued sent failed }
    }
  }
  """

  @roster_query """
  query($key: String!, $filter: String, $search: String) {
    flashbackOutreachRoster(archiveKey: $key, filter: $filter, search: $search) {
      personId: person_id fullName: full_name email phone claimed participation
      unsubscribed deleted emailReachable: email_reachable smsReachable: sms_reachable
      lastOutreach: last_outreach { channel status batch }
    }
  }
  """

  test "新三查询：未登录/普通用户 → forbidden；admin 空场次可读" do
    user = AccountsFixtures.register_user("outreach-q-plain")
    admin = AccountsFixtures.platform_admin("outreach-q-admin")
    archive = create_archive()

    res = post_graphql(@preview_query, user, %{"key" => archive.key, "channel" => "all"})
    assert [%{"code" => "forbidden"}] = res["errors"]

    res = post_graphql(@roster_query, user, %{"key" => archive.key})
    assert [%{"code" => "forbidden"}] = res["errors"]

    res = post_graphql(@preview_query, admin, %{"key" => archive.key, "channel" => "all"})
    preview = res["data"]["flashbackOutreachPreview"]
    assert preview["queued"] == 0
    assert preview["smsReady"] == true
  end

  test "预览分布与批次历史、名册触达结果（R4/R8/R9/AE8）" do
    admin = AccountsFixtures.platform_admin("outreach-q-data")
    archive = create_archive()
    create_person(archive, %{full_name: "邮甲", phone: nil, email: "a@example.com"})
    phone_only = create_person(archive, %{full_name: "短丙", email: nil})

    # 手机号与「短丙」错开——campaign 去重按联系方式判同批只收一封，共享默认值会被去重。
    failed_person = create_person(archive, %{full_name: "败丁", phone: "13900000009"})

    # 入队制造批次与触达结果；败丁的行推到 failed（模拟硬退信）
    assert {:ok, %{queued: 3}} = Dispatch.enqueue_for_archive(archive.key, "reconnect")

    row =
      Flashback.Outreach
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(person_id == ^failed_person.id)
      |> Ash.read_one!(authorize?: false)

    row
    |> Ash.Changeset.for_update(:mark_failed, %{})
    |> Ash.update!(authorize?: false)

    # 预览：三档分布（1 仅邮件 / 1 仅短信 / 1 双通道）
    res = post_graphql(@preview_query, admin, %{"key" => archive.key, "channel" => "all"})
    preview = res["data"]["flashbackOutreachPreview"]
    assert preview["queued"] == 3
    assert preview["emailOnly"] == 1
    assert preview["smsOnly"] == 1
    assert preview["both"] == 1

    # 批次历史：一行批次 + 通道计数（email 3 queued，其中 1 failed）
    res = post_graphql(@batches_query, admin, %{"key" => archive.key})
    assert [batch_row] = res["data"]["flashbackOutreachBatches"]
    # email 2 行（邮甲 queued + 败丁已置 failed）、sms 1 行（短丙 queued）
    assert batch_row["email"]["queued"] == 1
    assert batch_row["email"]["failed"] == 1
    assert batch_row["sms"]["queued"] == 1

    # 名册：完整联系方式 + 最近触达结果；send_failed 筛选（AE8）与搜索
    res = post_graphql(@roster_query, admin, %{"key" => archive.key})
    entries = res["data"]["flashbackOutreachRoster"]
    assert length(entries) == 3

    by_name = Map.new(entries, &{&1["fullName"], &1})
    failed_entry = by_name["败丁"]
    assert failed_entry["email"] == "w@example.com"
    assert %{"status" => "failed"} = failed_entry["lastOutreach"]

    res =
      post_graphql(@roster_query, admin, %{
        "key" => archive.key,
        "filter" => "send_failed",
        "search" => nil
      })

    assert [%{"fullName" => "败丁"}] = res["data"]["flashbackOutreachRoster"]

    res =
      post_graphql(@roster_query, admin, %{"key" => archive.key, "search" => "短"})

    assert [%{"fullName" => "短丙"}] = res["data"]["flashbackOutreachRoster"]
  end
end
