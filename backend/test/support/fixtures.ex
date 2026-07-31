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

  ## Options
  - `:email` - 指定邮箱(默认 `user_<n>@example.com`,保证唯一)
  - `:password` - 指定密码(默认 `password123`)
  """
  def seed_user(opts \\ []) do
    email = Keyword.get(opts, :email, "user_#{System.unique_integer([:positive])}@example.com")
    password = Keyword.get(opts, :password, "password123")

    {:ok, strategy} = AshAuthentication.Info.strategy(Cgc2046.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.Password.Actions.register(
        strategy,
        %{"email" => email, "password" => password, "password_confirmation" => password},
        []
      )

    user
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

  由 T03(Workspace 与多租户地基)落地实现:平台管理员创建并指定 Owner,
  返回 `%Workspace{}`。
  """
  def seed_workspace(_opts \\ []) do
    not_implemented!("seed_workspace/1", "T03 Workspace 与多租户地基")
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
