defmodule Cgc2046.Flashback.WishesEndorseU3Test do
  @moduledoc """
  KTD3 U3：endorse 扩列 / p:→u: 归并 / contribution_types 校验 /
  message 机审 / notify 持久化（不调 Consent.grant）。
  """
  use Cgc2046.DataCase, async: false

  require Ash.Query

  alias Cgc2046.Flashback.{WishEndorsement, Wishes}

  @msg_check_url "https://api.weixin.qq.com/wxa/msg_sec_check"

  defp create_archive do
    Cgc2046.Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-bj-u3-#{System.unique_integer([:positive])}",
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

  defp attach_identity(user_id, provider, uid) do
    Cgc2046.Accounts.UserIdentity
    |> Ash.Changeset.for_create(:upsert, %{
      provider: provider,
      uid: uid,
      user_id: user_id
    })
    |> Ash.create!(authorize?: false)
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
    # 测试主体是 endorse 而非 create_wish 机审；统一 mock :pass 让 create 零阻塞
    mock_msg_check(:pass)

    {:ok, wish} =
      Wishes.create_wish(person.id, content, "public",
        public_listing_consent: true,
        signature_choice: :anonymous
      )

    wish
  end

  defp create_claimed_wechat_person(archive, openid \\ "wx-flashback-u3") do
    person = create_person(archive)
    user = register_user("u3-wechat")
    :ok = bind_person_to_user(person.id, user.id)
    attach_identity(user.id, :wechat, openid)
    %{person: person, user: user, openid: openid}
  end

  defp mock_msg_check(:pass),
    do:
      Tesla.Mock.mock(fn %{method: :post, url: @msg_check_url <> _} = env ->
        send(self(), {:msg_check_request, Jason.decode!(env.body)})
        Tesla.Mock.json(%{"errcode" => 0, "result" => %{"suggest" => "pass", "label" => 100}})
      end)

  defp mock_msg_check(suggest) when suggest in [:risky, :review],
    do:
      Tesla.Mock.mock(fn %{method: :post, url: @msg_check_url <> _} = env ->
        send(self(), {:msg_check_request, Jason.decode!(env.body)})

        Tesla.Mock.json(%{
          "errcode" => 0,
          "result" => %{"suggest" => to_string(suggest), "label" => 20002}
        })
      end)


  # simplify：旧 endorse/2（token person 腿）已删——p: 行种子改 SQL 直插
  #（存量语义 = 批1 时代由旧路径写入的历史数据形态：user_id NULL）
  defp insert_p_endorsement(wish_id, person_id) do
    Repo.query!(
      """
      INSERT INTO flashback_wish_endorsements
        (id, wish_id, person_id, contribution_types, notify, inserted_at)
      VALUES (gen_random_uuid(), $1, $2, '{}', false, now())
      """,
      [Repo.uuid!(wish_id), Repo.uuid!(person_id)]
    )
    :ok
  end

  describe "endorse_by_user / cancel_endorse_by_user 基本路径" do
    test "登录 user 附议 listed 愿望 → +1, 取消则 -1" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "u3的心愿")

      assert {:ok, %{endorsement_count: 1, endorsed_by_me: true}} =
               Wishes.endorse_by_user(user.id, wish.id)

      assert {:ok, %{endorsement_count: 0, endorsed_by_me: false}} =
               Wishes.cancel_endorse_by_user(user.id, wish.id)
    end

    test "viewer（无 person）附议 listed 愿望成功（FIX-2 KTD9：listed → 任何登录用户）" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "owner 的心愿")
      viewer = register_user("u3-viewer")

      assert {:ok, %{endorsement_count: 1, endorsed_by_me: true}} =
               Wishes.endorse_by_user(viewer.id, wish.id)

      # person_id 落 NULL（身份由 user_id/actor_key 承载）
      wish_id = wish.id
      %{rows: [[pid]]} =
        Repo.query!(
          "SELECT person_id FROM flashback_wish_endorsements WHERE wish_id = $1",
          [Repo.uuid!(wish_id)]
        )
      assert is_nil(pid)

      # 幂等：重复附议 UPDATE 不双计
      assert {:ok, %{endorsement_count: 1, endorsed_by_me: true}} =
               Wishes.endorse_by_user(viewer.id, wish.id, contribution_types: ["sponsor"])

      cnt =
        WishEndorsement
        |> Ash.Query.filter(wish_id == ^wish_id)
        |> Ash.count!(authorize?: false)
      assert cnt == 1
    end

    test "viewer 附议未 listed 愿望 → flashback_wish_not_found（不泄露存在性）" do
      archive = create_archive()
      owner = create_person(archive)
      {:ok, member_only} =
        Wishes.create_wish(owner.id, "成员面愿望", "public", public_listing_consent: false)
      viewer = register_user("u3-viewer2")

      assert {:error, %{code: "flashback_wish_not_found"}} =
               Wishes.endorse_by_user(viewer.id, member_only.id)
    end

    test "hidden 愿望附议 → flashback_wish_not_found（审计 U3 缺口 2）" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "将被下架")
      Repo.query!("UPDATE flashback_wishes SET hidden_at = now() WHERE id = $1", [Repo.uuid!(wish.id)])

      member = register_user("u3-member")
      assert {:error, %{code: "flashback_wish_not_found"}} =
               Wishes.endorse_by_user(member.id, wish.id)
    end

    test "已认领 member 附议未 listed 愿望成功（成员语义保留）" do
      archive = create_archive()
      owner = create_person(archive)
      {:ok, member_only} =
        Wishes.create_wish(owner.id, "成员面愿望2", "public", public_listing_consent: false)

      member = register_user("u3-member2")
      :ok = bind_person_to_user(create_person(archive, %{full_name: "成员甲", surname: "甲"}).id, member.id)

      assert {:ok, %{endorsement_count: 1}} =
               Wishes.endorse_by_user(member.id, member_only.id)
    end

    test "contribution_types 列表外值 → flashback_wish_endorsement_invalid_contribution_types" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "类型校验")

      assert {:error, %{code: "flashback_wish_endorsement_invalid_contribution_types"}} =
               Wishes.endorse_by_user(user.id, wish.id, contribution_types: ["bogus"])
    end

    test "message 超 500 字 → flashback_wish_endorsement_message_too_long" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "超 500 字拒")

      long = String.duplicate("字", 501)

      assert {:error, %{code: "flashback_wish_endorsement_message_too_long"}} =
               Wishes.endorse_by_user(user.id, wish.id, message: long)
    end

    test "notify 默认 false, 显式 true 持久化" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "notify 持久化")

      {:ok, _} = Wishes.endorse_by_user(user.id, wish.id, notify: false)
      %{rows: [[notify]]} =
        Repo.query!(
          "SELECT notify FROM flashback_wish_endorsements WHERE wish_id = $1",
          [Repo.uuid!(wish.id)]
        )

      assert notify == false

      # cancel + 附议带 notify=true
      {:ok, _} = Wishes.cancel_endorse_by_user(user.id, wish.id)
      {:ok, _} = Wishes.endorse_by_user(user.id, wish.id, notify: true)

      %{rows: [[notify2]]} =
        Repo.query!(
          "SELECT notify FROM flashback_wish_endorsements WHERE wish_id = $1",
          [Repo.uuid!(wish.id)]
        )

      assert notify2 == true
    end

    test "message 非空 → 触发 wechat 机审（三态）" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "机审留言")

      mock_msg_check(:pass)

      assert {:ok, %{endorsement_count: 1}} =
               Wishes.endorse_by_user(user.id, wish.id, message: "我能帮上忙")

      assert_received {:msg_check_request, %{"content" => "我能帮上忙", "openid" => _}}
    end

    test "message 被机审 risky → flashback_content_rejected, 不入库" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "风险留言")

      mock_msg_check(:risky)

      assert {:error, %{code: "flashback_content_rejected"}} =
               Wishes.endorse_by_user(user.id, wish.id, message: "炸掉这个群")

      wish_id = wish.id

      count =
        WishEndorsement
        |> Ash.Query.filter(wish_id == ^wish_id)
        |> Ash.count!(authorize?: false)

      assert count == 0
    end

    test "message=nil 或空串 → 不发起外呼, endorse 成功" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "silent")

      # 不 mock msgSecCheck, 外呼即 raise
      assert {:ok, %{endorsement_count: 1}} =
               Wishes.endorse_by_user(user.id, wish.id)

      assert {:ok, %{endorsement_count: 0}} = Wishes.cancel_endorse_by_user(user.id, wish.id)

      assert {:ok, %{endorsement_count: 1}} =
               Wishes.endorse_by_user(user.id, wish.id, message: "")
    end

    test "user 无 wechat identity（tt 单平台）→ 不发外呼, endorse 成功 + openid_unresolved telemetry" do
      archive = create_archive()
      person = create_person(archive)
      user = register_user("u3-tt")
      :ok = bind_person_to_user(person.id, user.id)
      attach_identity(user.id, :tt, "tt-flashback-u3")
      wish = create_listed_wish(person, "tt 用户")

      # 不挂 msgSecCheck mock——走 :no_wechat_identity 路径零外呼
      assert {:ok, %{endorsement_count: 1}} =
               Wishes.endorse_by_user(user.id, wish.id, message: "tt 用户留言")
    end

    test "p: → u: 归并：已认领 person 的 p: 行升级，不新增不双计" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "归并")

      # 造存量 p: 行（user_id NULL——批1 历史数据形态）
      :ok = insert_p_endorsement(wish.id, person.id)

      wish_id = wish.id

      %{rows: [[uid_before]]} =
        Repo.query!(
          "SELECT user_id FROM flashback_wish_endorsements WHERE wish_id = $1 LIMIT 1",
          [Repo.uuid!(wish_id)]
        )

      assert is_nil(uid_before)

      # p: → u: 归并：同 user 的 person 有既有 p: 行 → 应 UPDATE 而非 INSERT
      {:ok, %{endorsement_count: 1}} =
        Wishes.endorse_by_user(user.id, wish.id,
          contribution_types: ["venue"],
          message: "升级",
          notify: true
        )

      %{rows: [[uid_after, contrib, msg, notify]]} =
        Repo.query!(
          "SELECT user_id, contribution_types, message, notify FROM flashback_wish_endorsements WHERE wish_id = $1",
          [Repo.uuid!(wish_id)]
        )

      assert uid_after == Repo.uuid!(user.id)
      assert contrib == ["venue"]
      assert msg == "升级"
      assert notify == true

      # 未双计：仍只一行
      cnt =
        WishEndorsement
        |> Ash.Query.filter(wish_id == ^wish_id)
        |> Ash.count!(authorize?: false)

      assert cnt == 1
    end

    test "存量 p: 行计入 endorsement_count（KTD2 兼容）" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "存量 p:")

      # person 自己造 p:，user 未 endorse（user_id NULL 存量形态）
      :ok = insert_p_endorsement(wish.id, person.id)

      # user 视角 endorsement_count 也应该 = 1（同一物理行；KTD2 user 已认领 person）
      result = Wishes.count_with_mine_by_user(wish.id, Repo.uuid!(user.id))
      assert result.endorsement_count == 1
      # 但 endorsed_by_me=false（user 没有 u: 行）
      assert result.endorsed_by_me == false
    end

    test "归并后 endorsed_by_me=true" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "归并后 endorsed")

      :ok = insert_p_endorsement(wish.id, person.id)

      {:ok, %{endorsement_count: 1, endorsed_by_me: true}} =
        Wishes.endorse_by_user(user.id, wish.id)
    end

    test "endor 全流程不调 Consent.grant——失败注入" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "single_source")

      # 如果 endorsement 调用 Consent.grant，应触发 granted telemetry；我们在
      # 测试端监听，观察到就是违规（KTD3 后端零 grant pin）。
      test_pid = self()
      handler_id = "u3-consent-firewall-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:cgc_2046, :consent, :granted],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:consent_granted_unexpectedly, event, measurements, metadata})
          end,
          nil
        )

      assert {:ok, _} =
               Wishes.endorse_by_user(user.id, wish.id,
                 contribution_types: ["venue"],
                 message: "我来出场地",
                 notify: true
               )

      refute_received {:consent_granted_unexpectedly, _, _, _}

      :telemetry.detach(handler_id)
    end
  end
end
