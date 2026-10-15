defmodule Cgc2046.Flashback.TokenMintBindConcurrencyTest do
  @moduledoc """
  #1102：铸 token 与绑定的真实并发（unboxed 双连接，确定性编排）。

  复现 Codex 在 PR #1109 指出的窗口：

      铸点读到 person.user_id 为 nil  →  绑定事务提交（扫不到 token）
      →  铸点插入新 token  →  漏网 token 生效

  编排：holder 任务模拟「进行中的绑定」——对 person 行取 `FOR UPDATE`、写入
  user_id，`pg_sleep` 定界后提交；测试进程在 holder 持锁之后才调铸 token。

  - 修复后：`mint_for_open_person/2` 的 `FOR UPDATE` 阻塞到 holder 提交，锁内复查
    看到 user_id 非空 → `:person_not_open`，零 token 落库。
  - 修复前（锁外读 + 裸插）：读不受行锁阻塞（MVCC 读到旧 nil）→ 照插 → 漏网。
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Accounts.SignInFlow
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Recover, Tokens}
  alias Cgc2046.Flashback.Workers.OutreachWorker
  alias Cgc2046.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      try do
        Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      catch
        :exit, {:noproc, _} -> :ok
        :exit, :noproc -> :ok
      end
    end)

    :ok
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  test "绑定事务持锁期间铸 token：阻塞至提交后拒铸，零 token 漏网" do
    {archive, person, user} =
      unboxed(fn ->
        archive =
          Flashback.EventArchive
          |> Ash.Changeset.for_create(:create, %{
            key: "mint-race-#{System.unique_integer([:positive])}",
            name: "Rails Girls Beijing",
            city: "北京"
          })
          |> Ash.create!(authorize?: false)

        person =
          Person
          |> Ash.Changeset.for_create(:create, %{
            archive_event_id: archive.id,
            full_name: "李盼",
            surname: "李",
            city: "北京",
            role: :learner,
            participation: :not_selected,
            email: "mint-race-#{System.unique_integer([:positive])}@example.com"
          })
          |> Ash.create!(authorize?: false)

        {:ok, user, _} =
          SignInFlow.find_or_create_user("+86139#{:rand.uniform(89_999_999) + 10_000_000}")

        {archive, person, user}
      end)

    on_exit(fn -> cleanup(archive, person, user) end)

    test_pid = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM flashback_people WHERE id = $1 FOR UPDATE", [
              Repo.uuid!(person.id)
            ])

            Repo.query!("UPDATE flashback_people SET user_id = $1 WHERE id = $2", [
              Repo.uuid!(user.id),
              Repo.uuid!(person.id)
            ])

            send(test_pid, :bind_in_progress)
            Repo.query!("SELECT pg_sleep(0.8)", [])
          end)
        end)
      end)

    receive do
      :bind_in_progress -> :ok
    after
      5_000 -> flunk("holder 未能在 5s 内持锁（编排失败）")
    end

    result = unboxed(fn -> Tokens.mint_for_open_person(person.id) end)
    Task.await(holder, 15_000)

    assert result == {:error, :person_not_open},
           "绑定进行中铸 token 必须被拒，实际 #{inspect(result)}"

    unboxed(fn ->
      {:ok, %{rows: [[n]]}} =
        Repo.query("SELECT count(*) FROM flashback_tokens WHERE person_id = $1", [
          Repo.uuid!(person.id)
        ])

      assert n == 0, "不得有 token 落库（漏网），实际 #{n} 枚"
    end)
  end

  test "outreach worker：执行中撞上绑定 → skip（不重试、不发信、行停 queued）" do
    # worker 的 `fetch_person` 是普通 SELECT，不被 holder 的行锁阻塞（MVCC 读到旧的
    # user_id = nil），于是通过「已认领」闸；随后 `mint_for_open_person` 的 FOR UPDATE
    # 阻塞至 holder 提交，锁内看到已绑定 → `:person_not_open`。worker 必须把它当成
    # 统计分母剔除的 skip，而不是硬错误（否则 Oban 重试、行落 failed）。
    {archive, person, user} =
      unboxed(fn ->
        archive =
          Flashback.EventArchive
          |> Ash.Changeset.for_create(:create, %{
            key: "mint-race-w-#{System.unique_integer([:positive])}",
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
            role: :learner,
            participation: :attended,
            email: "mint-race-w-#{System.unique_integer([:positive])}@example.com"
          })
          |> Ash.create!(authorize?: false)

        {:ok, user, _} =
          SignInFlow.find_or_create_user("+86139#{:rand.uniform(89_999_999) + 10_000_000}")

        {archive, person, user}
      end)

    on_exit(fn -> cleanup(archive, person, user) end)

    test_pid = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM flashback_people WHERE id = $1 FOR UPDATE", [
              Repo.uuid!(person.id)
            ])

            Repo.query!("UPDATE flashback_people SET user_id = $1 WHERE id = $2", [
              Repo.uuid!(user.id),
              Repo.uuid!(person.id)
            ])

            send(test_pid, :bind_in_progress)
            Repo.query!("SELECT pg_sleep(0.8)", [])
          end)
        end)
      end)

    receive do
      :bind_in_progress -> :ok
    after
      5_000 -> flunk("holder 未能在 5s 内持锁（编排失败）")
    end

    args = %{
      "person_id" => person.id,
      "channel" => "email",
      "batch" => "mint-race-w",
      "template" => "reconnect"
    }

    result = unboxed(fn -> perform_job(OutreachWorker, args) end)
    Task.await(holder, 15_000)

    assert result == :ok, "并发绑定应作为 skip 收口（:ok），实际 #{inspect(result)}"
    refute_receive {:email, _}, 50

    unboxed(fn ->
      {:ok, %{rows: [[n]]}} =
        Repo.query("SELECT count(*) FROM flashback_tokens WHERE person_id = $1", [
          Repo.uuid!(person.id)
        ])

      assert n == 0, "不得有 token 落库，实际 #{n} 枚"

      {:ok, %{rows: [[status]]}} =
        Repo.query("SELECT status FROM flashback_outreaches WHERE person_id = $1", [
          Repo.uuid!(person.id)
        ])

      assert status == "queued", "行应停在 queued（统计分母剔除），实际 #{status}"
    end)
  end

  test "找回邮件：发起时撞上绑定 → 该档案不铸不发，整封邮件不崩" do
    # 同一窗口在找回腿：`match_people` 的内存过滤（锁外）看到 user_id = nil，
    # `mint_for_open_person` 锁内看到已绑定 → 该档案被剔除。唯一档案被剔除时
    # 整封不发（无可发内容），且不能因未处理的返回值崩掉整个发起请求。
    email = "mint-race-r-#{System.unique_integer([:positive])}@example.com"

    {archive, person, user} =
      unboxed(fn ->
        archive =
          Flashback.EventArchive
          |> Ash.Changeset.for_create(:create, %{
            key: "mint-race-r-#{System.unique_integer([:positive])}",
            name: "Rails Girls Beijing",
            city: "北京"
          })
          |> Ash.create!(authorize?: false)

        person =
          Person
          |> Ash.Changeset.for_create(:create, %{
            archive_event_id: archive.id,
            full_name: "李盼",
            surname: "李",
            city: "北京",
            role: :learner,
            participation: :not_selected,
            email: email
          })
          |> Ash.create!(authorize?: false)

        {:ok, user, _} =
          SignInFlow.find_or_create_user("+86139#{:rand.uniform(89_999_999) + 10_000_000}")

        {archive, person, user}
      end)

    on_exit(fn -> cleanup(archive, person, user) end)

    test_pid = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM flashback_people WHERE id = $1 FOR UPDATE", [
              Repo.uuid!(person.id)
            ])

            Repo.query!("UPDATE flashback_people SET user_id = $1 WHERE id = $2", [
              Repo.uuid!(user.id),
              Repo.uuid!(person.id)
            ])

            send(test_pid, :bind_in_progress)
            Repo.query!("SELECT pg_sleep(0.8)", [])
          end)
        end)
      end)

    receive do
      :bind_in_progress -> :ok
    after
      5_000 -> flunk("holder 未能在 5s 内持锁（编排失败）")
    end

    result = unboxed(fn -> Recover.initiate(email, "9.9.9.#{:rand.uniform(200)}") end)
    Task.await(holder, 15_000)

    assert {:ok, %{dispatched: true}} = result
    refute_receive {:email, %{subject: "你的闪念间档案入口"}}, 100

    unboxed(fn ->
      {:ok, %{rows: [[n]]}} =
        Repo.query("SELECT count(*) FROM flashback_tokens WHERE person_id = $1", [
          Repo.uuid!(person.id)
        ])

      assert n == 0, "不得有 token 落库，实际 #{n} 枚"
    end)
  end

  defp cleanup(archive, person, user) do
    unboxed(fn ->
      Repo.query!("DELETE FROM flashback_tokens WHERE person_id = $1", [Repo.uuid!(person.id)])

      Repo.query!("DELETE FROM flashback_outreaches WHERE person_id = $1", [Repo.uuid!(person.id)])

      Repo.query!("DELETE FROM flashback_people WHERE id = $1", [Repo.uuid!(person.id)])
      Repo.query!("DELETE FROM flashback_event_archives WHERE id = $1", [Repo.uuid!(archive.id)])
      Repo.query!("DELETE FROM users WHERE id = $1", [Repo.uuid!(user.id)])
    end)
  end
end
