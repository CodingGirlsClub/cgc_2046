defmodule Cgc2046Web.GraphqlFlashbackTest do
  # RateLimit 全局 ETS 表（同 graphql_password_reset_test 先例）：async: false 防计数互相污染
  use Cgc2046Web.ConnCase, async: false

  require Ash.Query

  alias Cgc2046.Accounts.{PhoneVerificationCode, TokenCredential}
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Today, Token, Touch}
  alias Cgc2046.Repo

  @moduletag :capture_log

  # 原通道短信通知走 SendCloud test stub（Req.Test 拦截，未 stub 即 raise——
  # 同 graphql_phone_code_test 先例）；邮件通知走 Swoosh.Adapters.Test。
  setup do
    Req.Test.stub(Cgc2046.SmsSendCloudStub, fn conn ->
      Req.Test.json(conn, %{"result" => true})
    end)

    :ok
  end

  @phone "13900000001"
  @new_phone "13900000002"
  # 生产链路（requestPhoneCode/signInWithPhoneCode 先例）先 PhoneNumber.normalize
  # 再 issue/consume；测试注入凭证须用同一归一化形态，否则 hash 口径错位。
  @new_phone_normalized "+8613900000002"
  @email "wangxiaoming@example.com"

  defp post_graphql(query) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp enter_query(token) do
    """
    mutation { flashbackEnter(token: "#{token}") {
      line
      profile { full_name surname role participation applied_at
        archive { key name city occurredOn: occurred_on }
        answers { id questionKey: question_key rawText: raw_text
          fogSpans { start len reason } } }
      progress { quoteLevel: quote_level maskedPhone: masked_phone maskedEmail: masked_email
        today { nowStatus: now_status want need say sentToWallAt: sent_to_wall_at
          wantGiveTags: want_give_tags reconnectTags: reconnect_tags
          newsletterOptIn: newsletter_opt_in mobilization } }
      scatter { entries { photoKey: photo_key label dateStamp: date_stamp isMine: is_mine surname } }
    } }
    """
  end

  defp submit_mutation(token, inner \\ ~s(want: "想系统学 AI")) do
    """
    mutation { flashbackSubmitToday(token: "#{token}", input: { #{inner} }) {
      today { want need mobilization newsletterOptIn: newsletter_opt_in }
    } }
    """
  end

  defp send_to_wall_query(token) do
    """
    mutation { flashbackSendToWall(token: "#{token}") { sentToWallAt: sent_to_wall_at maskedPhone: masked_phone } }
    """
  end

  defp retract_query(token) do
    """
    mutation { flashbackRetract(token: "#{token}") { retracted sentToWallAt: sent_to_wall_at } }
    """
  end

  defp adjust_fog_query(token, answer_id, spans) do
    """
    mutation { flashbackAdjustFog(token: "#{token}", answerId: "#{answer_id}", spans: [#{spans}]) { answerId: answer_id fogSpans { start len reason } } }
    """
  end

  defp set_quote_query(token, level, rest \\ "") do
    """
    mutation { flashbackSetQuoteLicense(token: "#{token}", level: "#{level}"#{rest}) { level creditedNote: credited_note } }
    """
  end

  defp register_bind_query(token, phone, code) do
    """
    mutation { flashbackRegisterBind(token: "#{token}", phone: "#{phone}", code: "#{code}") { bound maskedPhone: masked_phone } }
    """
  end

  defp update_contact_query(token, phone, code) do
    """
    mutation { flashbackUpdateContact(token: "#{token}", phone: "#{phone}", code: "#{code}") { maskedPhone: masked_phone updated } }
    """
  end

  defp create_archive(attrs \\ %{}) do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          key: "2014-01-11-bj",
          name: "Rails Girls Beijing",
          city: "北京",
          occurred_on: ~D[2014-01-11]
        },
        attrs
      )
    )
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
        attrs
      )

    Person
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :archive_event_id, archive.id))
    |> Ash.create!(authorize?: false)
  end

  defp create_answer(person, key \\ "self_intro", text \\ "我在盛大做测试，想亲眼看看是不是。", fog_spans \\ nil) do
    Flashback.Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: key,
      raw_text: text,
      fog_spans: fog_spans
    })
    |> Ash.create!(authorize?: false)
  end

  # 明文 token 只在测试内存中存在（同 worker 形状：生成→hash 落库）。
  defp issue_token(person) do
    plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = TokenCredential.hash(plain)

    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
      |> Ash.create(authorize?: false)

    {plain, token}
  end

  defp touch_count(person_id, event) do
    Touch
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person_id and event == ^event)
    |> Ash.count!(authorize?: false)
  end

  defp reload_person(person_id) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^person_id)
    |> Ash.read_one!(authorize?: false)
  end

  # 注入验证码：同生产口径（normalize → issue），返回明文码。
  defp issue_code(phone, purpose) do
    {:ok, normalized} = Cgc2046.Accounts.PhoneNumber.normalize(phone)
    {:ok, code, _rid} = PhoneVerificationCode.issue(normalized, purpose)
    code
  end

  describe "flashbackEnter（分流 + 失效三态 + 行为事件）" do
    test "参与过 → 记忆线：档案原文完整 + 写 link_opened" do
      archive = create_archive()
      person = create_person(archive)
      answer = create_answer(person)
      {plain, _} = issue_token(person)

      res = post_graphql(enter_query(plain))

      payload = res["data"]["flashbackEnter"]
      assert payload["line"] == "memory"
      assert payload["progress"]["quoteLevel"] == "off"
      # 掩码回显：不出现明文（PII 断言见下）
      assert payload["progress"]["maskedPhone"] =~ "****"
      first_answer = payload["profile"]["answers"] |> List.first()
      assert first_answer["rawText"] == answer.raw_text
      assert payload["profile"]["archive"]["key"] == "2014-01-11-bj"
      assert touch_count(person.id, :link_opened) == 1
    end

    test "报名未入选 → 圆梦线" do
      archive = create_archive()
      person = create_person(archive, %{participation: :not_selected})
      {plain, _} = issue_token(person)

      res = post_graphql(enter_query(plain))
      assert res["data"]["flashbackEnter"]["line"] == "dream"
    end

    test "失效三态可区分：不存在 / 已注册 / 已删除" do
      archive = create_archive()
      person = create_person(archive)

      assert [%{"code" => "flashback_token_not_found"}] =
               post_graphql(enter_query("fb_totally_unknown"))["errors"]

      # 已注册：claim 置位（模拟 register_bind 的落点）
      {claimed_plain, claimed_token} = issue_token(person)

      {:ok, _} =
        claimed_token
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:claimed_by_user_id, Ecto.UUID.generate())
        |> Ash.update(authorize?: false)

      assert [%{"code" => "flashback_token_claimed"}] =
               post_graphql(enter_query(claimed_plain))["errors"]

      # 已删除：revoke 置位（模拟 U10 删除的落点）；独立 token，避免与 claimed 叠态
      {revoked_plain, revoked_token} = issue_token(person)

      {:ok, _} =
        revoked_token
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:revoked_at, DateTime.utc_now())
        |> Ash.update(authorize?: false)

      assert [%{"code" => "flashback_token_revoked"}] =
               post_graphql(enter_query(revoked_plain))["errors"]
    end

    test "未注册 token 可反复进入且进度保留（R1）" do
      archive = create_archive()
      person = create_person(archive)
      {plain, _} = issue_token(person)

      post_graphql(submit_mutation(plain))

      res = post_graphql(enter_query(plain))
      today = res["data"]["flashbackEnter"]["progress"]["today"]
      assert today["want"] == "想系统学 AI"

      assert post_graphql(enter_query(plain))["data"]["flashbackEnter"]["line"] == "memory"
    end
  end

  describe "flashbackEnter scatter（R5 数据驱动，批次二散照迭代）" do
    test "单场库：entries 仅本人一张（前端自适应 = 跳过问答直接显影）" do
      archive = create_archive()
      person = create_person(archive)
      create_answer(person)
      {plain, _} = issue_token(person)

      entries = post_graphql(enter_query(plain))["data"]["flashbackEnter"]["scatter"]["entries"]

      assert length(entries) == 1
      [only] = entries
      assert only["isMine"] == true
      assert only["label"] == "2014 · 北京"
      # 拍立得日期戳：只含日期（空格分隔），不含城市名（谜不泄底）
      assert only["dateStamp"] == "2014 01 11"
      refute only["dateStamp"] =~ "北京"
      assert only["photoKey"] == person.id
    end

    test "多场库：本人 + 其他场次各一人；线索标签与确定性摆位；无明文姓名" do
      _archive_bj = create_archive()

      archive_sh =
        create_archive(%{
          key: "2012-02-26-sh",
          name: "Rails Girls Shanghai",
          city: "上海",
          occurred_on: ~D[2012-02-26]
        })

      person =
        create_person(_archive_bj, %{
          full_name: "李一一",
          surname: "李",
          phone: "13911110001",
          email: "ly1@example.com"
        })

      create_answer(person)

      other =
        create_person(archive_sh, %{
          full_name: "陈查查",
          surname: "陈",
          phone: "13911110002",
          email: "cc@example.com"
        })

      create_answer(other)

      {plain, _} = issue_token(person)

      first = post_graphql(enter_query(plain))["data"]["flashbackEnter"]["scatter"]["entries"]
      second = post_graphql(enter_query(plain))["data"]["flashbackEnter"]["scatter"]["entries"]

      assert length(first) == 2
      # 确定性摆位：同一人两次进入顺序一致（渲染不跳位）
      assert first == second
      assert Enum.any?(first, &(&1["isMine"] && &1["label"] == "2014 · 北京"))
      assert Enum.any?(first, &(!&1["isMine"] && &1["label"] == "2012 · 上海"))
      # 每张（含非本人）都带各自场次的真实日期戳
      assert Enum.any?(first, &(&1["dateStamp"] == "2012 02 26"))
      assert Enum.any?(first, &(&1["dateStamp"] == "2014 01 11"))
      # 姓氏级脱敏由前端渲染；接口只出姓，不出明文姓名
      assert Enum.any?(first, &(&1["surname"] == "陈"))
      refute Enum.any?(first, &(&1["surname"] == "陈查查"))
    end
  end

  describe "flashbackSubmitToday（回信 + 意图事件）" do
    test "首次建行/再次更新 + 动员勾选拍平进 mobilization + 写 intent_submitted" do
      archive = create_archive()
      person = create_person(archive)
      {plain, _} = issue_token(person)

      inner =
        ~s(want: "想学 AI", want_give_tags: ["want_course"], mobilization_join_1024: true, mobilization_volunteer_lead: true, newsletter_opt_in: true, reconnect_tags: ["job"])

      res = post_graphql(submit_mutation(plain, inner))

      today = res["data"]["flashbackSubmitToday"]["today"]
      mobilization = Jason.decode!(today["mobilization"])
      assert mobilization["join_1024"] == true
      assert mobilization["volunteer_lead"] == true
      assert today["newsletterOptIn"] == true
      assert touch_count(person.id, :intent_submitted) == 1

      # 更新（覆盖式）
      post_graphql(submit_mutation(plain, ~s(want: "改学 Rust")))
      row = Repo.get_by(Today, person_id: person.id)
      assert row.want == "改学 Rust"
    end
  end

  describe "flashbackSendToWall / flashbackRetract（寄出与撤下）" do
    test "寄出置位 + sent_to_wall 事件；重复寄出幂等不重复计；撤下清回 nil" do
      archive = create_archive()
      person = create_person(archive)
      {plain, _} = issue_token(person)

      res = post_graphql(send_to_wall_query(plain))
      assert res["data"]["flashbackSendToWall"]["sentToWallAt"]
      assert touch_count(person.id, :sent_to_wall) == 1

      # 幂等：再寄一次，touch 不涨
      post_graphql(send_to_wall_query(plain))
      assert touch_count(person.id, :sent_to_wall) == 1

      # 撤下（R30 免注册一键）
      res = post_graphql(retract_query(plain))
      assert res["data"]["flashbackRetract"]["retracted"] == true
      assert is_nil(res["data"]["flashbackRetract"]["sentToWallAt"])
      assert is_nil(Repo.get_by(Today, person_id: person.id).sent_to_wall_at)
    end
  end

  describe "flashbackAdjustFog（雾面调整）" do
    test "只改 spans 不改 raw_text；他人答案 → flashback_answer_not_found" do
      archive = create_archive()
      alice = create_person(archive, %{full_name: "李雷", surname: "李"})
      bob = create_person(archive, %{full_name: "韩梅梅", surname: "韩"})
      answer = create_answer(alice)
      bob_answer = create_answer(bob)
      {plain, _} = issue_token(alice)

      res =
        post_graphql(adjust_fog_query(plain, answer.id, ~s({start: 2, len: 2, reason: "雇主"})))

      result = res["data"]["flashbackAdjustFog"]
      assert result["fogSpans"] == [%{"start" => 2, "len" => 2, "reason" => "雇主"}]
      assert Repo.get!(Flashback.Answer, answer.id).raw_text == answer.raw_text

      # 他人答案：与不存在同一错误（不泄露存在性）
      res = post_graphql(adjust_fog_query(plain, bob_answer.id, ~s({start: 0, len: 1})))
      assert [%{"code" => "flashback_answer_not_found"}] = res["errors"]
    end

    test "越界区间 → flashback_invalid_input" do
      archive = create_archive()
      person = create_person(archive)
      answer = create_answer(person)
      {plain, _} = issue_token(person)

      res = post_graphql(adjust_fog_query(plain, answer.id, ~s({start: 99, len: 5})))
      assert [%{"code" => "flashback_invalid_input"}] = res["errors"]
    end
  end

  describe "flashbackSetQuoteLicense（金句授权）" do
    test "两档写入 + 越界拒绝 + 关闭" do
      archive = create_archive()
      person = create_person(archive)
      create_answer(person, "funny_thing", "有意思的事：我想亲眼看看是不是。")
      {plain, _} = issue_token(person)

      res =
        post_graphql(
          set_quote_query(
            plain,
            "anonymous",
            ~s(, chosenQuoteSpans: [{questionKey: "funny_thing", start: 6, len: 8}])
          )
        )

      assert res["data"]["flashbackSetQuoteLicense"]["level"] == "anonymous"

      # 升档实名
      res = post_graphql(set_quote_query(plain, "credited", ~s(, creditedNote: "现在做无障碍开发")))
      assert res["data"]["flashbackSetQuoteLicense"]["level"] == "credited"
      assert res["data"]["flashbackSetQuoteLicense"]["creditedNote"] == "现在做无障碍开发"

      # 越界 span → 稳定 code
      res =
        post_graphql(
          set_quote_query(
            plain,
            "anonymous",
            ~s(, chosenQuoteSpans: [{questionKey: "funny_thing", start: 0, len: 999}])
          )
        )

      assert [%{"code" => "flashback_quote_span_out_of_bounds"}] = res["errors"]

      # 关闭（默认两档皆关的回退路径）
      res = post_graphql(set_quote_query(plain, "off"))
      assert res["data"]["flashbackSetQuoteLicense"]["level"] == "off"
    end
  end

  describe "flashbackRegisterBind（注册绑定）" do
    test "错码拒绝；对码绑定档案 + token 作废 + 会话 cookie 下发" do
      archive = create_archive()
      person = create_person(archive)
      {plain, token} = issue_token(person)

      res = post_graphql(register_bind_query(plain, @new_phone, "000000"))
      assert [%{"code" => "invalid_or_expired_code"}] = res["errors"]
      assert is_nil(reload_person(person.id).user_id)

      code = issue_code(@new_phone, :register)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => register_bind_query(plain, @new_phone, code)})

      body = json_response(conn, 200)
      assert body["data"]["flashbackRegisterBind"]["bound"] == true
      assert body["data"]["flashbackRegisterBind"]["maskedPhone"] =~ "****"
      assert conn.resp_cookies["cgc_token"].value

      # R1：注册即链接作废——此后 enter 被 claimed 拒绝
      assert [%{"code" => "flashback_token_claimed"}] =
               post_graphql(enter_query(plain))["errors"]

      bound = reload_person(person.id)
      refute is_nil(bound.user_id)

      {:ok, claimed} = Ash.reload(token, authorize?: false)
      assert claimed.claimed_by_user_id == bound.user_id
    end
  end

  describe "flashbackUpdateContact（R17/KTD7 防劫持）" do
    test "未验证新通道（错码）被拒：记录不动" do
      archive = create_archive()
      person = create_person(archive)
      {plain, _} = issue_token(person)

      res = post_graphql(update_contact_query(plain, @new_phone, "000000"))
      assert [%{"code" => "invalid_or_expired_code"}] = res["errors"]
      assert reload_person(person.id).phone == @phone
    end

    test "验证通过：手机号更新 + 原邮箱收「联系方式已变更」通知 + 只回显掩码" do
      archive = create_archive()
      person = create_person(archive)
      {plain, _} = issue_token(person)

      code = issue_code(@new_phone, :change_phone)

      res = post_graphql(update_contact_query(plain, @new_phone, code))
      assert res["data"]["flashbackUpdateContact"]["updated"] == true
      assert res["data"]["flashbackUpdateContact"]["maskedPhone"] =~ "****"
      assert reload_person(person.id).phone == @new_phone_normalized

      # 原通道通知（email 在记录内）
      assert_receive {:email, email}, 1_000
      assert {_name, address} = List.first(email.to)
      assert address == @email
      assert email.subject =~ "联系方式已变更"
    end
  end

  describe "投影纪律（KTD3：手机/邮箱明文不出现在任何响应）" do
    test "enter / updateContact 响应体不含明文" do
      archive = create_archive()
      person = create_person(archive)
      create_answer(person)
      {plain, _} = issue_token(person)

      enter_body =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => enter_query(plain)})
        |> json_response(200)

      encoded = Jason.encode!(enter_body)
      refute encoded =~ @phone
      refute encoded =~ @email

      code = issue_code(@new_phone, :change_phone)

      update_body = post_graphql(update_contact_query(plain, @new_phone, code))
      encoded = Jason.encode!(update_body)
      # 变更后的新号也不得回显明文（只有掩码）
      refute encoded =~ @new_phone
      refute encoded =~ @email
    end
  end

  describe "限流（同 token 高频调用）" do
    setup do
      :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())

      on_exit(fn ->
        :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
      end)

      :ok
    end

    # flashback token 面显式 max_attempts: 30（e2e 实测：默认 5 次会让完整
    # 首程 enter→revealed→submit→quote→send + 回访必然撞限）；防滥用语义
    # 保留——第 31 次拒绝。
    test "前 30 次（完整首程 + 回访余量）放行，第 31 次 → rate_limited" do
      archive = create_archive()
      person = create_person(archive)
      {plain, _} = issue_token(person)

      for i <- 1..30 do
        res = post_graphql(enter_query(plain))
        refute res["errors"], "attempt #{i} should pass, got: #{inspect(res["errors"])}"
      end

      assert [%{"code" => "rate_limited"}] = post_graphql(enter_query(plain))["errors"]
    end
  end

  describe "flashbackDelete（U10/R30 二次确认 + 双入口）" do
    test "confirm 错值被拒；正确值删除后 token revoked + 数据清除" do
      archive = create_archive()
      person = create_person(archive)
      create_answer(person)
      {plain, _} = issue_token(person)

      wrong = """
      mutation { flashbackDelete(token: "#{plain}", confirm: "yes") { deleted } }
      """

      assert [%{"code" => "flashback_delete_confirm_required"}] = post_graphql(wrong)["errors"]

      ok = """
      mutation { flashbackDelete(token: "#{plain}", confirm: "DELETE") { deleted deletedAt: deleted_at } }
      """

      res = post_graphql(ok)
      assert res["data"]["flashbackDelete"]["deleted"] == true

      # 删除后 token 失效（enter 不可再用）
      assert [%{"code" => "flashback_token_revoked"}] = post_graphql(enter_query(plain))["errors"]
    end

    test "会话腿删除（登录账号）；preview 返回摘要" do
      archive = create_archive()
      person = create_person(archive)
      create_answer(person)
      user = Cgc2046.AccountsFixtures.register_user("fb-del-session")

      person
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.update!(authorize?: false)

      preview = """
      query { flashbackDeletePreview {
        personId: person_id fullName: full_name endorsementCount: endorsement_count alreadyDeleted: already_deleted } }
      """

      res = post_as_user(preview, user)
      payload = res["data"]["flashbackDeletePreview"]
      assert payload["fullName"] == "王小明"
      assert payload["alreadyDeleted"] == false

      deletion = """
      mutation { flashbackDelete(confirm: "DELETE") { deleted } }
      """

      res = post_as_user(deletion, user)
      assert res["data"]["flashbackDelete"]["deleted"] == true

      # 账号解绑后再查 → not_bound
      res = post_as_user(preview, user)
      assert [%{"code" => "flashback_person_not_bound"}] = res["errors"]
    end
  end

  describe "写面会话身份（U9/R28：token 省略 → 登录账号绑定档案）" do
    # signIn 换 Bearer（同 graphql_complexity_budget_test 的 token_for 形状）。
    defp token_for(user) do
      mutation = """
      mutation { signIn(login: "#{user.email}", password: "#{Cgc2046.AccountsFixtures.password()}") { id } }
      """

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => mutation})

      assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
      conn.resp_cookies["cgc_token"].value
    end

    defp post_as_user(query, user) do
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token_for(user)}")
      |> post("/api/graphql", %{"query" => query})
      |> json_response(200)
    end

    defp bind_person(person, user_id) do
      person
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:user_id, user_id)
      |> Ash.update!(authorize?: false)
    end

    test "绑定账号：adjustFog / setQuoteLicense / submitToday（不写 intent_submitted）" do
      archive = create_archive()
      person = create_person(archive)
      answer = create_answer(person)
      user = Cgc2046.AccountsFixtures.register_user("fb-session-edit")
      bind_person(person, user.id)

      fog_query = """
      mutation { flashbackAdjustFog(answerId: "#{answer.id}", spans: [{start: 0, len: 5}]) {
        answerId: answer_id fogSpans { start len } } }
      """

      res = post_as_user(fog_query, user)
      assert [%{"start" => 0, "len" => 5}] = res["data"]["flashbackAdjustFog"]["fogSpans"]

      quote_query = """
      mutation { flashbackSetQuoteLicense(level: "anonymous") { level } }
      """

      res = post_as_user(quote_query, user)
      assert res["data"]["flashbackSetQuoteLicense"]["level"] == "anonymous"

      # 回访端恢复选中态：写后 capsule me 回读授权档（P3 契约）
      capsule_query = """
      query { flashbackCapsule { me { quoteLevel: quote_level } } }
      """

      res = post_as_user(capsule_query, user)
      assert res["data"]["flashbackCapsule"]["me"]["quoteLevel"] == "anonymous"

      today_query = """
      mutation { flashbackSubmitToday(input: { want: "回访编辑" }) { today { want } } }
      """

      res = post_as_user(today_query, user)
      assert res["data"]["flashbackSubmitToday"]["today"]["want"] == "回访编辑"
      # 四率度量首程漏斗：回访编辑不重计意图率（KTD10 口径）
      assert touch_count(person.id, :intent_submitted) == 0
    end

    test "未登录且无 token → auth_required（不泄露存在性）" do
      endorse_query = """
      query { flashbackDeletePreview { personId: person_id } }
      """

      res =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => endorse_query})
        |> json_response(200)

      assert [%{"code" => "flashback_auth_required"}] = res["errors"]
    end

    test "登录未绑定档案 → person_not_bound" do
      user = Cgc2046.AccountsFixtures.register_user("fb-session-unbound")

      endorse_query = """
      query { flashbackDeletePreview { personId: person_id } }
      """

      res = post_as_user(endorse_query, user)
      assert [%{"code" => "flashback_person_not_bound"}] = res["errors"]
    end
  end

  describe "flashbackCapsule 全字段冒烟（实测 bug：uuid binary 炸 Jason 序列化）" do
    test "roster 的 id 经完整字段 query 可 JSON 序列化且为 uuid 文本" do
      archive = create_archive()
      person = create_person(archive)
      other = create_person(archive, %{full_name: "李雷", surname: "李"})

      # 李雷寄出（带雾面答案），本人不寄出（虚线位分支同场覆盖）
      create_answer(other, "self_intro", "在盛大做测试。喜欢周末骑行。", [%{"start" => 0, "len" => 6}])

      Today
      |> Ash.Changeset.for_create(:create, %{person_id: other.id})
      |> Ash.create!(authorize?: false)
      |> Ash.Changeset.for_update(:update, %{
        sent_to_wall_at: DateTime.utc_now(),
        now_status: "还在写代码"
      })
      |> Ash.update!(authorize?: false)

      {plain, _token} = issue_token(person)

      query = """
      query { flashbackCapsule(token: "#{plain}") {
        me { id fullName quoteLevel: quote_level quote answers { questionKey: question_key text } today { sentToWallAt: sent_to_wall_at } }
        archives { key isMine appliedCount: applied_count attendedCount: attended_count
          roster { id surnameMasked: surname_masked sentToWallAt: sent_to_wall_at
            today { nowStatus: now_status } answers { questionKey: question_key segments { text fog len } } } }
      } }
      """

      res =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => query})
        |> json_response(200)

      # 修复前此处是 500（Jason.EncodeError：裸查询 id 为 16 字节 binary）
      refute Map.has_key?(res, "errors")

      capsule = res["data"]["flashbackCapsule"]
      assert capsule["me"]["id"] =~ ~r/^[0-9a-f-]{36}$/
      # 授权档默认关（R31：无授权行为 off）
      assert capsule["me"]["quoteLevel"] == "off"

      [archive_payload] = capsule["archives"]
      assert length(archive_payload["roster"]) == 2

      for entry <- archive_payload["roster"] do
        assert entry["id"] =~ ~r/^[0-9a-f-]{36}$/
      end

      quiet = Enum.find(archive_payload["roster"], &(&1["surnameMasked"] == "王**"))
      assert quiet["today"] == nil
      assert quiet["answers"] == []

      sent = Enum.find(archive_payload["roster"], &(&1["surnameMasked"] == "李*"))
      assert sent["today"]["nowStatus"] == "还在写代码"
      # 雾化文本：PII 段 ▓▓ 遮蔽，原文不出现
      [answer] = sent["answers"]
      fog = Enum.find(answer["segments"], & &1["fog"])
      plain = Enum.find(answer["segments"], &(!&1["fog"]))
      assert fog["len"] == 6 and fog["text"] == ""
      assert plain["text"] == "。喜欢周末骑行。"
      refute inspect(answer["segments"]) =~ "在盛大做测试"
    end

    test "city 参数（R34 城市钉）：roster 按人城市过滤；cities 全量不缩" do
      archive = create_archive()
      person = create_person(archive, %{city: "北京"})
      create_person(archive, %{full_name: "李雷", surname: "李", city: "上海"})

      {plain, _token} = issue_token(person)

      query = """
      query { flashbackCapsule(token: "#{plain}", city: "上海") {
        cities
        archives { key roster { surnameMasked: surname_masked city } }
      } }
      """

      res =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => query})
        |> json_response(200)

      refute Map.has_key?(res, "errors")

      capsule = res["data"]["flashbackCapsule"]
      # 钉条数据源全量（去重排序），不随 city 过滤收缩
      assert capsule["cities"] == ["上海", "北京"]

      [archive_payload] = capsule["archives"]
      assert [%{"surnameMasked" => "李*", "city" => "上海"}] = archive_payload["roster"]
    end
  end
end
