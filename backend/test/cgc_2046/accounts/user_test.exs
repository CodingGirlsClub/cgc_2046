defmodule Cgc2046.Accounts.UserTest do
  use Cgc2046.DataCase, async: true

  alias Cgc2046.Accounts.User
  alias AshAuthentication.Info, as: AuthInfo

  @email "tester@example.com"
  @password "sup3r-secret-password"

  defp password_strategy do
    AuthInfo.strategy!(User, :password)
  end

  describe "register_with_password" do
    test "creates a user and issues a JWT in metadata" do
      strategy = password_strategy()

      assert {:ok, user} =
               AshAuthentication.Strategy.action(strategy, :register, %{
                 email: @email,
                 password: @password
               })

      assert to_string(user.email) == @email
      refute is_nil(user.__metadata__.token)
      assert is_binary(user.__metadata__.token)
      # token has JWT structure: three dot-separated base64url segments
      assert length(String.split(user.__metadata__.token, ".")) == 3
    end

    test "does not expose hashed_password publicly" do
      strategy = password_strategy()

      assert {:ok, user} =
               AshAuthentication.Strategy.action(strategy, :register, %{
                 email: @email,
                 password: @password
               })

      assert user.hashed_password != @password

      # ADR-0004：profile 字段已迁至 WorkspaceProfile，User 仅保留全局身份
      assert Ash.Resource.Info.public_attributes(User) |> Enum.map(& &1.name) ==
               [
                 :id,
                 :email,
                 # phone public 化是 password_phone 策略 identity_field 校验强制
                 # (plan 002 U2)；敏感出口仍由手写 GraphQL resolver 单点控制。
                 :phone,
                 :is_platform_admin,
                 :display_name,
                 :locale,
                 :onboarding_invitation_dismissed_at
               ]
    end

    test "rejects duplicate email" do
      strategy = password_strategy()

      assert {:ok, _user} =
               AshAuthentication.Strategy.action(strategy, :register, %{
                 email: @email,
                 password: @password
               })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AshAuthentication.Strategy.action(strategy, :register, %{
                 email: @email,
                 password: @password
               })

      assert Enum.any?(errors, fn error ->
               Exception.message(error) =~ "email"
             end)
    end

    test "rejects a password shorter than 8 chars" do
      strategy = password_strategy()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AshAuthentication.Strategy.action(strategy, :register, %{
                 email: @email,
                 password: "short"
               })

      assert Enum.any?(errors, fn
               %Ash.Error.Changes.InvalidArgument{field: :password} -> true
               _ -> false
             end)
    end

    test "rejects an invalid email format" do
      strategy = password_strategy()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AshAuthentication.Strategy.action(strategy, :register, %{
                 email: "not-an-email",
                 password: @password
               })

      assert Enum.any?(errors, fn
               %Ash.Error.Changes.InvalidAttribute{field: :email} -> true
               _ -> false
             end)
    end

    # Phase 1：users.email/hashed_password 列放宽可空（小程序手机号用户无邮箱），
    # 但 password 策略注册必须仍强制 email——由 register action 的
    # require_attributes: [:email] 在策略层兜底（非 DB 层）。
    test "still requires email after users.email became nullable" do
      strategy = password_strategy()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AshAuthentication.Strategy.action(strategy, :register, %{
                 password: @password
               })

      assert Enum.any?(errors, fn error ->
               Exception.message(error) =~ "email"
             end)
    end
  end

  describe "sign_in_with_password" do
    setup do
      strategy = password_strategy()

      {:ok, _user} =
        AshAuthentication.Strategy.action(strategy, :register, %{
          email: @email,
          password: @password
        })

      :ok
    end

    test "signs in with correct credentials and issues a fresh token" do
      strategy = password_strategy()

      assert {:ok, user} =
               AshAuthentication.Strategy.action(strategy, :sign_in, %{
                 email: @email,
                 password: @password
               })

      assert to_string(user.email) == @email
      assert is_binary(user.__metadata__.token)
      assert length(String.split(user.__metadata__.token, ".")) == 3
    end

    test "fails with an invalid password" do
      strategy = password_strategy()

      assert {:error, %AshAuthentication.Errors.AuthenticationFailed{}} =
               AshAuthentication.Strategy.action(strategy, :sign_in, %{
                 email: @email,
                 password: "wrong-password"
               })
    end

    test "fails for an unknown email" do
      strategy = password_strategy()

      assert {:error, %AshAuthentication.Errors.AuthenticationFailed{}} =
               AshAuthentication.Strategy.action(strategy, :sign_in, %{
                 email: "nobody@example.com",
                 password: @password
               })
    end
  end

  describe "token verification" do
    test "a token issued at sign_up verifies and resolves to the subject" do
      strategy = password_strategy()

      {:ok, user} =
        AshAuthentication.Strategy.action(strategy, :register, %{
          email: @email,
          password: @password
        })

      token = user.__metadata__.token

      assert {:ok, claims, User} = AshAuthentication.Jwt.verify(token, User)
      assert claims["sub"] == "user?id=#{user.id}"
      assert claims["purpose"] == "user"
    end
  end

  describe "update_locale (i18n Phase 1)" do
    defp register(email) do
      strategy = password_strategy()

      {:ok, user} =
        AshAuthentication.Strategy.action(strategy, :register, %{
          email: email,
          password: @password
        })

      user
    end

    test "writes a valid locale for the owner" do
      user = register("locale-owner@example.com")

      assert {:ok, updated} =
               user
               |> Ash.Changeset.for_update(:update_locale, %{locale: "en"}, actor: user)
               |> Ash.update(actor: user)

      assert updated.locale == "en"

      assert {:ok, updated} =
               updated
               |> Ash.Changeset.for_update(:update_locale, %{locale: "zh-CN"}, actor: user)
               |> Ash.update(actor: user)

      assert updated.locale == "zh-CN"
    end

    test "rejects an unsupported locale value" do
      user = register("locale-invalid@example.com")

      assert {:error, %Ash.Error.Invalid{}} =
               user
               |> Ash.Changeset.for_update(:update_locale, %{locale: "fr"}, actor: user)
               |> Ash.update(actor: user)
    end

    test "forbids updating another user's locale (policy: OwnUser)" do
      user = register("locale-target@example.com")
      other = register("locale-other@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               user
               |> Ash.Changeset.for_update(:update_locale, %{locale: "en"}, actor: other)
               |> Ash.update(actor: other)
    end
  end

  describe "dismiss_onboarding_invitation (首公里 R2)" do
    test "writes a dismissal timestamp for the owner" do
      user = register("dismiss-owner@example.com")

      assert user.onboarding_invitation_dismissed_at == nil

      assert {:ok, updated} =
               user
               |> Ash.Changeset.for_update(:dismiss_onboarding_invitation, %{}, actor: user)
               |> Ash.update(actor: user)

      assert %DateTime{} = updated.onboarding_invitation_dismissed_at
    end

    test "is idempotent: repeat call succeeds and preserves the first timestamp" do
      user = register("dismiss-idem@example.com")

      assert {:ok, first} =
               user
               |> Ash.Changeset.for_update(:dismiss_onboarding_invitation, %{}, actor: user)
               |> Ash.update(actor: user)

      assert {:ok, second} =
               first
               |> Ash.Changeset.for_update(:dismiss_onboarding_invitation, %{}, actor: user)
               |> Ash.update(actor: user)

      assert second.onboarding_invitation_dismissed_at ==
               first.onboarding_invitation_dismissed_at
    end

    test "forbids dismissing for another user (policy: OwnUser)" do
      user = register("dismiss-target@example.com")
      other = register("dismiss-other@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               user
               |> Ash.Changeset.for_update(:dismiss_onboarding_invitation, %{}, actor: other)
               |> Ash.update(actor: other)
    end
  end
end
