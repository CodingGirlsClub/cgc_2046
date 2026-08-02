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

      assert Ash.Resource.Info.public_attributes(User) |> Enum.map(& &1.name) ==
               [
                 :id,
                 :email,
                 :is_platform_admin,
                 :display_name,
                 :avatar_url,
                 :location,
                 :about,
                 :skills,
                 :visibility
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
end
