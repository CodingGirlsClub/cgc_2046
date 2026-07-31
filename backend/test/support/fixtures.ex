defmodule Cgc2046.TestFixtures do
  @moduledoc """
  后端共享测试夹具:seed 用户/token/workspace/membership 帮助函数。

  这是 TDD 主接缝(HTTP 集成测试)的数据底座 —— 所有用例共享同一套 seed
  帮助函数,保证"真实 token、真实角色、真实 workspace"(见
  docs/spec-平台核心与OpenClacky对接.md「测试接缝」)。

  ## 实现说明(blockers-first)

  T01 阶段仅建立函数**契约**(签名 + 文档);T02 落地 `seed_user/1` 与
  `seed_token/2`,其余实现体在对应资源落地后填充:

  - `seed_user/1` 依赖 User 资源(全局)→ **T02 已落地**
  - `seed_token/2` 依赖认证 token 白名单 → **T02 已落地**
  - `seed_workspace/1` 依赖 Workspace 资源 → T03 Workspace 与多租户地基
  - `seed_membership/3` 依赖 WorkspaceMembership 资源 → T04 成员与角色

  在资源落地前调用会 raise,错误信息指明由哪张票提供实现。
  """

  @doc """
  创建一个全局用户(默认 email 唯一)。

  T02 已落地:通过 Password 策略注册用户并返回 `%User{}`。
  T03 增强:`is_platform_admin` 通过 `Ash.Seed.seed!/2` 直接落库
  (Ash.Seed 绕过 action 校验/授权,适合测试数据;密码经 Bcrypt 哈希)。

  ## Options
  - `:email` - 指定邮箱(默认 `user_<n>@example.com`,保证唯一)
  - `:password` - 指定密码(默认 `password123`)
  - `:is_platform_admin` - 是否平台管理员(默认 `false`)
  """
  def seed_user(opts \\ []) do
    email = Keyword.get(opts, :email, "user_#{System.unique_integer([:positive])}@example.com")
    password = Keyword.get(opts, :password, "password123")
    is_platform_admin = Keyword.get(opts, :is_platform_admin, false)

    {:ok, hashed_password} = AshAuthentication.BcryptProvider.hash(password)

    Ash.Seed.seed!(Cgc2046.Accounts.User, %{
      email: email,
      hashed_password: hashed_password,
      is_platform_admin: is_platform_admin
    })
  end

  @doc """
  创建一个平台管理员(`is_platform_admin: true`)。

  T03 落地:平台管理员是唯一能创建 Workspace 并指定 Owner 的角色
  (见 docs/spec-平台核心与OpenClacky对接.md §4)。
  """
  def seed_platform_admin(opts \\ []) do
    seed_user(Keyword.put_new(opts, :is_platform_admin, true))
  end

  @doc """
  为用户签发一个认证 token(白名单模式)。

  T02 已落地:通过 JWT 签发返回可放入 `Authorization: Bearer <token>`
  的 token 字符串(白名单模式下 token 自动写入 Token 资源)。
  """
  def seed_token(user, _opts \\ []) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    token
  end

  @doc """
  创建一个 Workspace(默认 join_policy: :request)。

  T03 已落地:平台管理员创建并指定 Owner,返回 `%Workspace{}`。
  若未显式传 `:admin`,当 `owner` 本身是平台管理员时以 owner 为 actor,
  否则自动 seed 一个平台管理员作为 actor(测试数据底座,符合"仅平台管理员
  可创建并指定 Owner"的验收语义)。

  ## Options
  - `:slug` - 唯一 slug(默认 `ws_<n>`,保证唯一)
  - `:name` - 展示名(默认取 slug)
  - `:join_policy` - open/request/invite_only(默认 `:request`)
  - `:owner` - Owner User(必传)
  - `:admin` - 执行创建的平台管理员 actor(可选,见上)
  """
  def seed_workspace(opts \\ []) do
    slug = Keyword.get(opts, :slug, "ws_#{System.unique_integer([:positive])}")
    name = Keyword.get(opts, :name, slug)
    join_policy = Keyword.get(opts, :join_policy, :request)
    owner = Keyword.fetch!(opts, :owner)

    admin =
      cond do
        Keyword.has_key?(opts, :admin) -> opts[:admin]
        Map.get(owner, :is_platform_admin, false) -> owner
        true -> seed_platform_admin()
      end

    case Ash.create(
           Cgc2046.Workspaces.Workspace,
           %{slug: slug, name: name, join_policy: join_policy, owner_id: owner.id},
           actor: admin
         ) do
      {:ok, workspace} ->
        workspace

      {:error, error} ->
        raise "Cgc2046.TestFixtures.seed_workspace/1 创建失败: #{Exception.message(error)}"
    end
  end

  @doc """
  把用户加入 Workspace 并创建 membership(可带角色)。

  由 T04(成员与角色)落地实现:返回 `%WorkspaceMembership{}`。
  """
  def seed_membership(_user, _workspace, _opts \\ []) do
    not_implemented!("seed_membership/3", "T04 成员与角色")
  end

  defp not_implemented!(fun, ticket) do
    raise "Cgc2046.TestFixtures.#{fun} 尚未实现:依赖 #{ticket} 落地的资源。"
  end
end
