defmodule Cgc2046.Accounts.MiniprogramRaceTest do
  @moduledoc """
  并发 find-or-create 竞态测试（Phase 1 身份基座，§6 并发规则）。

  真实并发模型：并发 Task 经 `Sandbox.unboxed_run` 拿真实连接（真实提交），
  Req.Test 栅栏对齐 code2session 后同时进入 find-or-create。
  `users_unique_phone_index` 部分唯一索引保证只有一个创建者，败者重读获胜者行。

  断言不变量：恰好一个 User、每个平台恰好一条 Identity、全部登录成功且同一 User。
  """
  use Cgc2046.DataCase, async: false

  alias AshAuthentication.{Info, Strategy}
  alias Cgc2046.Accounts.{User, UserIdentity}
  alias Cgc2046.MiniprogramFixtures, as: Fixtures

  @internal_context [context: %{private: %{ash_authentication?: true}}]

  setup do
    # 测试进程读/断言走 DataCase 的 shared 沙箱连接（能读到已提交数据）；
    # 并发 Task 必须用 unboxed_run 拿真实连接（真实提交）——否则共享事务内
    # 并发读互相可见，竞态窗口消失；且沙箱回滚会让"已建用户"在断言前消失。
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, &cleanup/0)
    end)

    :ok
  end

  defp cleanup do
    # 本文件 fixture 的 phone 数字统一以 139 开头（其余测试用 138），openid 带 "-race-" 标识
    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      """
      DELETE FROM membership_roles WHERE membership_id IN (
        SELECT id FROM workspace_memberships WHERE user_id IN (
          SELECT id FROM users WHERE phone LIKE '+86139%'
        )
      )
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      "DELETE FROM workspace_memberships WHERE user_id IN (SELECT id FROM users WHERE phone LIKE '+86139%')",
      []
    )

    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      "DELETE FROM workspace_profiles WHERE user_id IN (SELECT id FROM users WHERE phone LIKE '+86139%')",
      []
    )

    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      "DELETE FROM tokens WHERE subject IN (SELECT 'user?id=' || id::text FROM users WHERE phone LIKE '+86139%')",
      []
    )

    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      "DELETE FROM user_identities WHERE uid LIKE '%-race-%'",
      []
    )

    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      "DELETE FROM users WHERE phone LIKE '+86139%'",
      []
    )
  end

  defp sign_in(platform, code, encrypted_data, iv) do
    Strategy.action(Info.strategy!(User, :miniprogram), :sign_in, %{
      platform: platform,
      code: code,
      encrypted_data: encrypted_data,
      iv: iv
    })
  end

  # 并发同平台同手机号：N 个任务栅栏对齐后同时 find-or-create
  test "N 个并发同平台登录（同手机号）：恰好建一个 User + 一条 Identity" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    phone = "139race#{suffix}"
    openid = "w-race-#{suffix}"
    session_key = Fixtures.new_session_key()
    payload = Fixtures.phone_payload(phone)
    n = 4

    barrier = start_supervised!({Fixtures.Barrier, n})
    wrap = Fixtures.barrier_wrap(barrier)

    body =
      wrap.(fn _conn ->
        Fixtures.code2session_body(:wechat, %{openid: openid, session_key: session_key})
      end)

    Fixtures.stub_code2session(%{wechat: body})

    tasks =
      for i <- 1..n do
        {encrypted_data, iv} = Fixtures.encrypt_phone(session_key, payload)

        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, fn ->
            sign_in("wechat", "race-code-#{i}", encrypted_data, iv)
          end)
        end)
      end

    results = Task.await_many(tasks, 15_000)

    assert Enum.all?(results, &match?({:ok, _}, &1)),
           "全部并发登录应成功，实际 #{inspect(results)}"

    user_ids = results |> Enum.map(fn {:ok, user} -> user.id end) |> Enum.uniq()
    assert length(user_ids) == 1, "并发建号应收敛到同一 User，实际 #{inspect(user_ids)}"

    normalized_phone = "+86" <> String.replace(phone, ~r/\D/, "")
    users = Ash.read!(User, @internal_context) |> Enum.filter(&(&1.phone == normalized_phone))
    assert length(users) == 1, "phone=#{normalized_phone} 应恰好一个 User"

    identities = Ash.read!(UserIdentity, @internal_context) |> Enum.filter(&(&1.uid == openid))
    assert length(identities) == 1, "(wechat, #{openid}) 应恰好一条 Identity"
    assert hd(identities).user_id == hd(user_ids)
  end

  # 并发跨平台同手机号：两个平台同时首登 → 归一到同一 User，各挂一条 Identity
  test "并发跨平台登录（同手机号）：归一到同一 User，两平台各一条 Identity" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    phone = "139race#{suffix}"
    wechat_openid = "w-race-x-#{suffix}"
    tt_openid = "t-race-x-#{suffix}"
    payload = Fixtures.phone_payload(phone)

    barrier = start_supervised!({Fixtures.Barrier, 2})
    wrap = Fixtures.barrier_wrap(barrier)

    wechat_key = Fixtures.new_session_key()
    tt_key = Fixtures.new_session_key()

    Fixtures.stub_code2session(%{
      wechat:
        wrap.(fn _conn ->
          Fixtures.code2session_body(:wechat, %{openid: wechat_openid, session_key: wechat_key})
        end),
      tt:
        wrap.(fn _conn ->
          Fixtures.code2session_body(:tt, %{openid: tt_openid, session_key: tt_key})
        end)
    })

    {wechat_ed, wechat_iv} = Fixtures.encrypt_phone(wechat_key, payload)
    {tt_ed, tt_iv} = Fixtures.encrypt_phone(tt_key, payload)

    tasks = [
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, fn ->
          sign_in("wechat", "race-x-w", wechat_ed, wechat_iv)
        end)
      end),
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, fn ->
          sign_in("tt", "race-x-t", tt_ed, tt_iv)
        end)
      end)
    ]

    results = Task.await_many(tasks, 15_000)
    assert Enum.all?(results, &match?({:ok, _}, &1))

    user_ids = results |> Enum.map(fn {:ok, user} -> user.id end) |> Enum.uniq()
    assert length(user_ids) == 1, "跨平台并发建号应归一到同一 User，实际 #{inspect(user_ids)}"

    identities =
      Ash.read!(UserIdentity, @internal_context)
      |> Enum.filter(&(&1.uid in [wechat_openid, tt_openid]))

    assert length(identities) == 2
    assert Enum.all?(identities, &(&1.user_id == hd(user_ids)))
  end

  # 并发重登（同一已存在账号）：吊销与签发交织下，全部成功且至少保留一个活跃 token
  test "并发重登（同平台已有账号）：全部成功，至少一个活跃 token 存活" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    phone = "139race#{suffix}"
    openid = "w-race-re-#{suffix}"
    session_key = Fixtures.new_session_key()
    payload = Fixtures.phone_payload(phone)

    body =
      Fixtures.code2session_body(:wechat, %{openid: openid, session_key: session_key})

    Fixtures.stub_code2session(%{wechat: body})

    # 先建立一个已登录账号（产生首个活跃 token）
    {ed0, iv0} = Fixtures.encrypt_phone(session_key, payload)

    assert {:ok, user} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, fn ->
               sign_in("wechat", "race-re-0", ed0, iv0)
             end)

    # 并发重登：每个任务都是"吊销 subject 全部旧 token → 签发新 token"，
    # 交织下最终活跃 token 数取决于时序——断言下界而非精确值。
    n = 3
    barrier = start_supervised!({Fixtures.Barrier, n})
    wrap = Fixtures.barrier_wrap(barrier)

    Fixtures.stub_code2session(%{
      wechat:
        wrap.(fn _conn ->
          Fixtures.code2session_body(:wechat, %{openid: openid, session_key: session_key})
        end)
    })

    tasks =
      for i <- 1..n do
        {encrypted_data, iv} = Fixtures.encrypt_phone(session_key, payload)

        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, fn ->
            sign_in("wechat", "race-re-#{i}", encrypted_data, iv)
          end)
        end)
      end

    results = Task.await_many(tasks, 15_000)

    assert Enum.all?(results, &match?({:ok, _}, &1)),
           "并发重登应全部成功，实际 #{inspect(results)}"

    assert Enum.all?(results, fn {:ok, u} -> u.id == user.id end)

    subject = AshAuthentication.user_to_subject(user)

    {:ok, live} =
      Cgc2046.Accounts.Token
      |> Ash.Query.for_read(:stored_for_subject, %{subject: subject})
      |> Ash.read(@internal_context)

    assert length(live) >= 1, "并发重登后应至少一个活跃 token，实际 0"
  end
end
