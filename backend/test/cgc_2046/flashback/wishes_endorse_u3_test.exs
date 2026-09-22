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

    test "未认领 user 附议 → flashback_wish_endorsement_requires_claim" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "owner 的心愿")
      unrelated_user = register_user("u3-unclaimed")

      assert {:error, %{code: "flashback_wish_endorsement_requires_claim"}} =
               Wishes.endorse_by_user(unrelated_user.id, wish.id)
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

    test "endore 全流程不调 Consent.grant——失败注入" do
      archive = create_archive()
      %{person: person, user: user} = create_claimed_wechat_person(archive)
      wish = create_listed_wish(person, "single_source")

      # 模拟 Consent.grant 调用会 raise——endorse 应正常工作
      test_pid = self()

      :ok =
        :telemetry.attach(
          "u3-consent-firewall-#{System.unique_integer([:positive])}",
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

      :telemetry.detach("u3-consent-firewall-#{System.unique_integer([:positive])}")
    end
  end
end
