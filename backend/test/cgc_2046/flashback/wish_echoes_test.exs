defmodule Cgc2046.Flashback.WishEchoesTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures
  alias Cgc2046.Flashback.{EventArchive, Person, WishEndorsement, WishEchoes, Wishes}
  alias Cgc2046.Notifications.NotificationWorker
  alias Cgc2046.Repo

  require Ash.Query

  @moduletag :capture_log

  defp create_listed_wish do
    archive =
      EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "echo-dispatch-#{System.unique_integer([:positive])}",
        name: "Rails Girls Beijing",
        city: "北京",
        occurred_on: ~D[2014-01-11]
      })
      |> Ash.create!(authorize?: false)

    person =
      Person
      |> Ash.Changeset.for_create(:create, %{
        archive_event_id: archive.id,
        full_name: "王小明",
        surname: "王",
        city: "北京",
        participation: :attended,
        email: "echo-dispatch-#{System.unique_integer([:positive])}@example.test"
      })
      |> Ash.create!(authorize?: false)

    {:ok, wish} =
      Wishes.create_wish(person.id, "主办方 Echo 通知愿望", "public", public_listing_consent: true)

    {wish, person}
  end

  defp create_echo(wish, content) do
    {:ok, echo} = WishEchoes.create_draft(wish.id, content)
    echo
  end

  defp endorsement(wish_id, user_id) do
    WishEndorsement
    |> Ash.Query.filter(wish_id == ^wish_id and user_id == ^user_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp used_at(endorsement_id) do
    %{rows: [[used_at]]} =
      Repo.query!(
        "SELECT echo_notification_used_at FROM flashback_wish_endorsements WHERE id = $1",
        [Repo.uuid!(endorsement_id)]
      )

    used_at
  end

  defp insert_identity(user_id, provider, uid) do
    Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, NOW(), NOW())
      """,
      [to_string(provider), uid, Repo.uuid!(user_id)]
    )
  end

  test "首次发布只为入队成功的附议标记机会，后续 Echo/更正/撤回不重复通知" do
    user = AccountsFixtures.register_user("wish-echo-dispatch")
    insert_identity(user.id, :wechat, "wish-echo-dispatch-openid")
    {wish, _person} = create_listed_wish()
    assert {:ok, _} = Wishes.endorse_by_user(user.id, wish.id, notify: true)
    endorsement = endorsement(wish.id, user.id)

    first = create_echo(wish, "首条主办方回响")
    assert {:ok, published} = WishEchoes.publish(first.id, Ecto.UUID.generate())
    assert published.status == "published"
    assert not is_nil(used_at(endorsement.id))

    assert [%{args: first_args}] = all_enqueued(worker: NotificationWorker)
    assert first_args["template_key"] == "flashback_wish_echo"
    assert first_args["data"]["wish_id"] == wish.id
    assert first_args["data"]["echo_id"] == first.id
    assert first_args["data"]["endorsement_id"] == endorsement.id

    second = create_echo(wish, "第二条主办方回响")
    assert {:ok, _published} = WishEchoes.publish(second.id, Ecto.UUID.generate())
    assert length(all_enqueued(worker: NotificationWorker)) == 1

    assert {:ok, _corrected} = WishEchoes.correct(first.id, "更正后的回响")
    assert {:ok, _revoked} = WishEchoes.revoke(second.id)
    assert length(all_enqueued(worker: NotificationWorker)) == 1
  end

  test "无身份时保留通知机会，之后出现身份可由下一条 Echo 消耗" do
    user = AccountsFixtures.register_user("wish-echo-late-identity")
    {wish, _person} = create_listed_wish()
    assert {:ok, _} = Wishes.endorse_by_user(user.id, wish.id, notify: true)
    endorsement = endorsement(wish.id, user.id)

    first = create_echo(wish, "暂无身份")
    assert {:ok, _published} = WishEchoes.publish(first.id, Ecto.UUID.generate())
    assert is_nil(used_at(endorsement.id))
    assert all_enqueued(worker: NotificationWorker) == []

    insert_identity(user.id, :wechat, "wish-echo-late-identity-openid")
    second = create_echo(wish, "身份已就绪")
    assert {:ok, _published} = WishEchoes.publish(second.id, Ecto.UUID.generate())
    assert not is_nil(used_at(endorsement.id))
    assert length(all_enqueued(worker: NotificationWorker)) == 1
  end

  test "notify=false 与没有 user_id 的附议都不入队，也不标记机会" do
    user = AccountsFixtures.register_user("wish-echo-no-notify")
    insert_identity(user.id, :wechat, "wish-echo-no-notify-openid")
    {wish, person} = create_listed_wish()
    assert {:ok, _} = Wishes.endorse_by_user(user.id, wish.id, notify: false)

    Repo.query!(
      """
      INSERT INTO flashback_wish_endorsements
        (id, wish_id, person_id, contribution_types, notify, inserted_at)
      VALUES (gen_random_uuid(), $1, $2, '{}', TRUE, NOW())
      """,
      [Repo.uuid!(wish.id), Repo.uuid!(person.id)]
    )

    echo = create_echo(wish, "没有符合条件的收件人")
    assert {:ok, _published} = WishEchoes.publish(echo.id, Ecto.UUID.generate())
    assert all_enqueued(worker: NotificationWorker) == []

    %{rows: rows} =
      Repo.query!(
        """
        SELECT echo_notification_used_at
        FROM flashback_wish_endorsements
        WHERE wish_id = $1
        """,
        [Repo.uuid!(wish.id)]
      )

    assert Enum.all?(rows, fn [used_at] -> is_nil(used_at) end)
  end

  test "入队失败会回滚首次发布和一次性标记" do
    {user, wish, person, archive_id, endorsement_id, echo} =
      unboxed(fn ->
        user =
          AccountsFixtures.register_user("wish-echo-enqueue-failure-#{Ecto.UUID.generate()}")

        insert_identity(
          user.id,
          :wechat,
          "wish-echo-enqueue-failure-#{Ecto.UUID.generate()}"
        )

        {wish, person} = create_listed_wish()
        assert {:ok, _} = Wishes.endorse_by_user(user.id, wish.id, notify: true)
        endorsement = endorsement(wish.id, user.id)
        echo = create_echo(wish, "队列暂不可用")
        {user, wish, person, person.archive_event_id, endorsement.id, echo}
      end)

    cleanup_on_exit(user.id, wish.id, person.id, archive_id)
    unboxed(&fail_echo_enqueue/0)

    assert {:error, :enqueue_failed} =
             unboxed(fn -> WishEchoes.publish(echo.id, Ecto.UUID.generate()) end)

    unboxed(fn ->
      assert {:ok, reloaded_echo} =
               Ash.get(Cgc2046.Flashback.WishEcho, echo.id, authorize?: false)

      assert reloaded_echo.status == "draft"
      assert is_nil(used_at(endorsement_id))

      assert %{rows: []} =
               Repo.query!(
                 "SELECT id FROM oban_jobs WHERE args->>'endorsement_id' = $1",
                 [endorsement_id]
               )
    end)
  end

  # Real publish -> queued worker -> captured provider request; no external messages.
  defp queued_delivery(prior_echo \\ false) do
    receiver = self()

    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/cgi-bin/message/subscribe/send" <> _} = env ->
        send(receiver, {:echo_delivery, Jason.decode!(env.body)})
        Tesla.Mock.json(%{"errcode" => 0})
    end)

    user = AccountsFixtures.register_user("echo-delivery-#{System.unique_integer([:positive])}")
    insert_identity(user.id, :wechat, "echo-delivery-openid")
    {:ok, _} = Cgc2046.Notifications.Consent.grant(user.id, :wechat, "flashback_wish_echo")
    {wish, person} = create_listed_wish()

    if prior_echo do
      old = create_echo(wish, "附议前已经公开的旧回响")
      {:ok, _} = WishEchoes.publish(old.id, Ecto.UUID.generate())
    end

    {:ok, _} = Wishes.endorse_by_user(user.id, wish.id, notify: true)
    echo = create_echo(wish, "第一版回响")
    {:ok, _} = WishEchoes.publish(echo.id, Ecto.UUID.generate())
    [job] = all_enqueued(worker: NotificationWorker)
    %{user: user, wish: wish, person: person, echo: echo, args: job.args, job: job}
  end

  test "真实发布的通知直达独立许愿树，发送前刷新更正内容并消费一次授权" do
    %{user: user, wish: wish, echo: echo, args: args} = queued_delivery()
    {:ok, _} = WishEchoes.correct(echo.id, "发送前更正的回响")
    assert :ok = perform_job(NotificationWorker, args)
    assert_receive {:echo_delivery, body}
    assert body["page"] == "pages/flashback-wishes/index?wishId=#{wish.id}"
    assert body["data"]["thing1"] == %{"value" => "发送前更正的回响"}

    assert {:ok, 0} =
             Cgc2046.Notifications.Consent.remaining(user.id, :wechat, "flashback_wish_echo")

    assert {:discard, "consent_exhausted"} = perform_job(NotificationWorker, args)
    refute_receive {:echo_delivery, _}
  end

  test "触发通知的回响撤回后，不回退到附议前的旧回响" do
    %{user: user, echo: echo, job: job} = queued_delivery(true)
    {:ok, _} = WishEchoes.revoke(echo.id)
    assert :ok = perform_job(NotificationWorker, job.args)
    refute_receive {:echo_delivery, _}

    assert {:ok, 1} =
             Cgc2046.Notifications.Consent.remaining(user.id, :wechat, "flashback_wish_echo")
  end

  test "入队后发布另一条回响，不替换本次通知的回响" do
    %{wish: wish, job: job} = queued_delivery()
    newer = create_echo(wish, "后来发布的新回响")
    {:ok, _} = WishEchoes.publish(newer.id, Ecto.UUID.generate())
    assert :ok = perform_job(NotificationWorker, job.args)
    assert_receive {:echo_delivery, body}
    assert body["data"]["thing1"] == %{"value" => "第一版回响"}
  end

  test "缺少事件身份的任务明确拒绝，不猜回响、不消耗授权" do
    %{user: user, args: args} = queued_delivery()
    args = put_in(args, ["data"], Map.delete(args["data"], "echo_id"))
    assert {:discard, "echo_identity_missing"} = perform_job(NotificationWorker, args)
    refute_receive {:echo_delivery, _}

    assert {:ok, 1} =
             Cgc2046.Notifications.Consent.remaining(user.id, :wechat, "flashback_wish_echo")
  end

  for state <- [:canceled, :notify_off, :hidden, :deleted, :revoked, :wrong_user] do
    test "队列等待后 #{state} 不再外发且保留授权" do
      %{user: user, wish: wish, person: person, echo: echo, args: args} = queued_delivery()

      args =
        case unquote(state) do
          :canceled ->
            {:ok, _} = Wishes.cancel_endorse_by_user(user.id, wish.id)
            args

          :notify_off ->
            {:ok, _} = Wishes.endorse_by_user(user.id, wish.id, notify: false)
            args

          :hidden ->
            Repo.query!("UPDATE flashback_wishes SET hidden_at = NOW() WHERE id = $1", [
              Repo.uuid!(wish.id)
            ])

            args

          :deleted ->
            {:ok, _} = Wishes.soft_delete_wish(wish.id, person.id)
            args

          :revoked ->
            {:ok, _} = WishEchoes.revoke(echo.id)
            args

          :wrong_user ->
            Map.put(args, "user_id", Ecto.UUID.generate())
        end

      assert :ok = perform_job(NotificationWorker, args)
      refute_receive {:echo_delivery, _}

      assert {:ok, 1} =
               Cgc2046.Notifications.Consent.remaining(user.id, :wechat, "flashback_wish_echo")
    end
  end

  defp fail_echo_enqueue do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION cgc_test_block_echo_enqueue() RETURNS trigger AS
    $$ BEGIN
      IF NEW.args->>'template_key' = 'flashback_wish_echo' THEN
        RAISE EXCEPTION 'test injected echo enqueue failure';
      END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    Repo.query!("""
    CREATE TRIGGER block_echo_enqueue BEFORE INSERT ON oban_jobs
    FOR EACH ROW
    WHEN (NEW.args->>'template_key' = 'flashback_wish_echo')
    EXECUTE FUNCTION cgc_test_block_echo_enqueue()
    """)
  end

  defp release_echo_enqueue do
    Repo.query!("DROP TRIGGER IF EXISTS block_echo_enqueue ON oban_jobs")
    Repo.query!("DROP FUNCTION IF EXISTS cgc_test_block_echo_enqueue")
  end

  defp cleanup_on_exit(user_id, wish_id, person_id, archive_id) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      unboxed(fn ->
        release_echo_enqueue()
        Repo.query!("DELETE FROM oban_jobs WHERE args->>'user_id' = $1", [user_id])
        Repo.query!("DELETE FROM flashback_wishes WHERE id = $1", [Repo.uuid!(wish_id)])
        Repo.query!("DELETE FROM flashback_people WHERE id = $1", [Repo.uuid!(person_id)])

        Repo.query!("DELETE FROM flashback_event_archives WHERE id = $1", [Repo.uuid!(archive_id)])

        Repo.query!("DELETE FROM user_identities WHERE user_id = $1", [Repo.uuid!(user_id)])
        Repo.query!("DELETE FROM users WHERE id = $1", [Repo.uuid!(user_id)])
      end)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
