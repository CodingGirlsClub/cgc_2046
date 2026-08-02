defmodule Cgc2046.Accounts.VisibilityReadTest do
  @moduledoc """
  visibility 三档改造（2026-08-02）读取策略矩阵测试。

  覆盖 ReadUserByVisibility 判定：
  - 本人永远可读（三档）
  - :public  所有登录用户可读
  - :workspace 同属任一工作区（共同 membership）的登录用户可读；非共同工作区不可读
  - :only_me 仅本人可读
  - 匿名一律不可读（返回空列表，不暴露存在性）
  """

  use Cgc2046.DataCase, async: false

  require Ash.Query

  alias Cgc2046.Accounts.{User, Workspace, WorkspaceMembership}
  alias AshAuthentication.Info, as: AuthInfo

  @password "sup3r-secret-password"

  defp password_strategy do
    AuthInfo.strategy!(User, :password)
  end

  defp register_user(email) do
    assert {:ok, user} =
             AshAuthentication.Strategy.action(password_strategy(), :register, %{
               email: email,
               password: @password
             })

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp make_admin(user) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp set_visibility(user, visibility) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET visibility = $1 WHERE id = $2",
        [Atom.to_string(visibility), Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp read_target(actor, target_id) do
    q = Ash.Query.filter(User, id == ^target_id)

    case Ash.read(q, actor: actor, authorize?: true, domain: Cgc2046.GlobalApi) do
      {:ok, rows} -> length(rows)
      {:error, %Ash.Error.Invalid{}} -> 0
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp seed_actor_trio do
    stamp = System.os_time(:millisecond)

    a = register_user("vis-a-#{stamp}@example.com")
    b = register_user("vis-b-#{stamp}@example.com")
    c = register_user("vis-c-#{stamp}@example.com")

    admin = make_admin(a)

    ws =
      Ash.create!(
        Workspace,
        %{
          slug: "vis-ws-#{stamp}",
          name: "Vis WS",
          join_policy: :invite_only,
          sponsorship_enabled: false
        },
        action: :create,
        actor: admin,
        authorize?: true,
        domain: Cgc2046.GlobalApi
      )

    # B 加入 ws（A 是 owner，Owner 可创建成员）
    Ash.create!(
      WorkspaceMembership,
      %{user_id: b.id},
      tenant: ws.id,
      actor: admin,
      authorize?: true,
      domain: Cgc2046.GlobalApi
    )

    {a, b, c, ws}
  end

  describe "ReadUserByVisibility 读取矩阵" do
    test "本人永远可读（public / workspace / only_me 三档）" do
      {a, _b, _c, _ws} = seed_actor_trio()

      for visibility <- [:public, :workspace, :only_me] do
        a = set_visibility(a, visibility)
        assert read_target(a, a.id) == 1, "本人读自己 #{visibility} 应可见"
      end
    end

    test "only_me：仅本人可读（同 ws 与异 ws 均不可读）" do
      {a, b, c, _ws} = seed_actor_trio()
      a = set_visibility(a, :only_me)

      assert read_target(a, a.id) == 1, "本人可读"
      assert read_target(b, a.id) == 0, "同 ws 用户不可读"
      assert read_target(c, a.id) == 0, "非 ws 用户不可读"
    end

    test "workspace：同 ws 用户可读；非 ws 用户不可读" do
      {a, b, c, _ws} = seed_actor_trio()
      a = set_visibility(a, :workspace)

      assert read_target(a, a.id) == 1, "本人可读"
      assert read_target(b, a.id) == 1, "同 ws 用户可读"
      assert read_target(c, a.id) == 0, "非 ws 用户不可读"
    end

    test "public：所有登录用户可读" do
      {a, b, c, _ws} = seed_actor_trio()
      a = set_visibility(a, :public)

      assert read_target(a, a.id) == 1, "本人可读"
      assert read_target(b, a.id) == 1, "同 ws 用户可读"
      assert read_target(c, a.id) == 1, "非 ws 用户可读"
    end

    test "匿名一律不可读（public 也不可见）" do
      {a, _b, _c, _ws} = seed_actor_trio()
      a = set_visibility(a, :public)

      assert read_target(nil, a.id) == 0, "匿名读 public 应返回空列表"
    end

    test "新注册用户默认 only_me" do
      stamp = System.os_time(:millisecond)
      user = register_user("vis-default-#{stamp}@example.com")
      assert user.visibility == :only_me
    end
  end
end
