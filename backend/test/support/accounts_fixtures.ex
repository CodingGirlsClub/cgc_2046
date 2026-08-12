defmodule Cgc2046.AccountsFixtures do
  @moduledoc """
  授权测试布置的唯一入口（账户 / 工作台 / 成员资格）。

  - `register_user/1`：password strategy 注册用户，邮箱 `"<prefix>-<uuid>@example.com"`
    防冲突；固定密码经 `password/0` 暴露，登录流程断言统一引用，不在测试文件硬编码。
  - `platform_admin/1`：注册后走 User `:set_platform_admin` 域 action 提权
    （`authorize?: false` 模拟种子/运维路径，与 `mix cgc2046.promote_admin` 同一动作）。
    禁止在测试里手写 `UPDATE users SET is_platform_admin` 裸 SQL 绕过。
  - `create_workspace/2` / `add_member/3` / `workspace_with_member/1`：工作台与成员资格布置，
    成员资格统一走 `MembershipContext.admit_member`（`on_conflict: :idempotent`）——
    幂等语义：同一 (workspace, user) 重复调用返回既有 membership 且不补座角色。
  - `remove_membership/2`：域没有 remove 路径，此处的 SQL 是布置而非被测对象。
  - `reset_platform_admins/0`：清掉 sandbox 外残留的 admin 标记（仅 async: false 且
    断言全局 admin 计数的测试在 setup 调用），同样走 `:set_platform_admin` 域 action。
  """

  import ExUnit.Assertions

  alias AshAuthentication.Info
  alias AshAuthentication.Strategy
  alias Cgc2046.Accounts.{MembershipContext, User, Workspace}

  require Ash.Query

  @password "sup3r-secret-password"

  @doc "注册用户的固定密码（登录流程断言统一引用）。"
  def password, do: @password

  def register_user(prefix) do
    email = "#{prefix}-#{Ecto.UUID.generate()}@example.com"

    {:ok, user} =
      User
      |> Info.strategy!(:password)
      |> Strategy.action(:register, %{email: email, password: @password})

    user
  end

  def platform_admin(prefix \\ "admin") do
    user = register_user(prefix)

    user
    |> Ash.Changeset.for_update(:set_platform_admin, %{is_platform_admin: true},
      authorize?: false
    )
    |> Ash.update!()
  end

  def create_workspace(actor, attrs \\ %{}) do
    Workspace
    |> Ash.Changeset.for_create(:create, workspace_defaults(attrs))
    |> Ash.create!(actor: actor)
  end

  defp workspace_defaults(attrs) do
    suffix = Ecto.UUID.generate()

    Map.merge(
      %{slug: "ws-#{suffix}", name: "Workspace #{suffix}", join_policy: :request},
      attrs
    )
  end

  def add_member(workspace, user, role_names \\ [:member]) do
    {:ok, membership} =
      MembershipContext.admit_member(user.id, workspace.id, role_names, on_conflict: :idempotent)

    membership
  end

  @doc """
  支配模式组合：owner 注册并持有 workspace（Owner 成员），member 注册并以
  `member_roles` 入座。返回 `%{owner:, workspace:, member:, membership:}`。

  Workspace create policy 仅 platform admin 可建：此处以 `authorize?: false`
  建工作台（布置旁路，与 add_member/3 同），owner 作为 actor 由 Workspace
  create 的 after_action 入座 Owner 成员资格（域默认路径）。
  """
  def workspace_with_member(opts \\ []) do
    owner = register_user("owner")

    workspace =
      Workspace
      |> Ash.Changeset.for_create(
        :create,
        workspace_defaults(Keyword.get(opts, :workspace_attrs, %{}))
      )
      |> Ash.create!(actor: owner, authorize?: false)

    member = register_user("member")
    membership = add_member(workspace, member, Keyword.get(opts, :member_roles, [:member]))

    %{owner: owner, workspace: workspace, member: member, membership: membership}
  end

  @doc """
  移除用户的成员资格（先删 membership_roles 关联记录，避免外键保护
  "would leave records behind"）。域没有 remove 路径，此处的 SQL 是布置而非被测对象。
  """
  def remove_membership(workspace, user) do
    loaded =
      Ash.load!(workspace, :memberships, tenant: workspace.id, actor: user, authorize?: false)

    membership = Enum.find(loaded.memberships, &(&1.user_id == user.id))
    assert membership != nil

    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      "DELETE FROM membership_roles WHERE membership_id = $1",
      [Ecto.UUID.dump!(membership.id)]
    )

    Ash.destroy!(membership, tenant: workspace.id, actor: user, authorize?: false)
    :ok
  end

  @doc """
  清掉全部 platform admin 标记（sandbox 外残留清理，走 `:set_platform_admin` 域 action）。
  仅 async: false 且断言全局 admin 计数（≥1 admin 不变量）的测试在 setup 调用。
  """
  def reset_platform_admins do
    User
    |> Ash.Query.filter(is_platform_admin == true)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn user ->
      user
      |> Ash.Changeset.for_update(:set_platform_admin, %{is_platform_admin: false},
        authorize?: false
      )
      |> Ash.update!()
    end)

    :ok
  end
end
