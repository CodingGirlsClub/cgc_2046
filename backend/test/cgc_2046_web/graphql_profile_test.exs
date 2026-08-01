defmodule Cgc2046Web.GraphqlProfileTest do
  use Cgc2046Web.ConnCase, async: true

  require Ash.Query

  alias Cgc2046.Accounts.User
  alias AshAuthentication.Info, as: AuthInfo

  @admin_email "gql-profile-admin@example.com"
  @user_email "gql-profile-user@example.com"
  @password "sup3r-secret-password"

  defp password_strategy do
    AuthInfo.strategy!(User, :password)
  end

  defp register_user(email, password) do
    strategy = password_strategy()

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: password
             })

    user
  end

  defp admin_user do
    user = register_user(@admin_email, @password)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp graphql_post(conn, query, token \\ nil) do
    conn =
      if token do
        put_req_header(conn, "authorization", "Bearer #{token}")
      else
        conn
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp sign_in_token(email, password) do
    query = """
    mutation {
      signIn(email: "#{email}", password: "#{password}") {
        id
        token
      }
    }
    """

    res = graphql_post(build_conn(), query)
    assert %{"data" => %{"signIn" => %{"token" => token}}} = res
    token
  end

  describe "me query (#68 Profile contract)" do
    test "anonymous is unauthorized" do
      res = graphql_post(build_conn(), "query { me { id email } }")
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "returns current user profile fields (id/email/displayName/avatarUrl/isPlatformAdmin)" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res = graphql_post(build_conn(), me_query(), token)

      assert %{
               "data" => %{
                 "me" => %{
                   "id" => id,
                   "email" => email,
                   "displayName" => display_name,
                   "avatarUrl" => avatar_url,
                   "isPlatformAdmin" => is_platform_admin
                 }
               }
             } = res

      assert is_binary(id)
      assert email == @admin_email
      assert display_name == nil
      assert avatar_url == nil
      assert is_platform_admin == true
    end

    test "regular user me reflects profile updates" do
      _user = register_user(@user_email, @password)
      token = sign_in_token(@user_email, @password)

      res = graphql_post(build_conn(), me_query(), token)
      assert %{"data" => %{"me" => %{"isPlatformAdmin" => false}}} = res
    end
  end

  describe "updateProfile mutation (#68 Profile contract)" do
    test "updates displayName and avatarUrl for current user" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res =
        graphql_post(
          build_conn(),
          update_profile_query("阿麦", "https://cdn.example.com/avatar.png"),
          token
        )

      assert %{
               "data" => %{
                 "updateProfile" => %{
                   "id" => _id,
                   "email" => email,
                   "displayName" => "阿麦",
                   "avatarUrl" => "https://cdn.example.com/avatar.png",
                   "isPlatformAdmin" => true
                 }
               }
             } = res

      assert email == @admin_email

      # me 反映更新
      res = graphql_post(build_conn(), me_query(), token)
      assert %{"data" => %{"me" => %{"displayName" => "阿麦"}}} = res
    end

    test "trims displayName before persisting" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res = graphql_post(build_conn(), update_profile_query("  小麦  ", nil), token)
      assert %{"data" => %{"updateProfile" => %{"displayName" => "小麦"}}} = res
    end

    test "blank displayName is rejected" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res = graphql_post(build_conn(), update_profile_query("   ", nil), token)

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "must not be blank"))
    end

    test "displayName is required by input contract" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateProfile(input: { avatarUrl: "https://cdn.example.com/a.png" }) {
              id
            }
          }
          """,
          token
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "displayName"))
    end

    test "anonymous is unauthorized" do
      res =
        graphql_post(
          build_conn(),
          update_profile_query("someone", nil)
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "user cannot update another user via direct Ash action (policy: self only)" do
      admin = admin_user()
      _user = register_user(@user_email, @password)

      user =
        Ash.read_one!(
          Ash.Query.filter(User, email == ^@user_email),
          authorize?: false,
          domain: Cgc2046.GlobalApi
        )

      # 普通用户尝试更新平台管理员：policy 应拒绝（id != actor.id）
      result =
        admin
        |> Ash.Changeset.for_update(:update_profile, %{display_name: "hacked"})
        |> Ash.update(actor: user)

      assert {:error, error} = result
      assert Exception.message(Ash.Error.to_error_class(error)) =~ "forbidden"
    end
  end

  defp me_query do
    """
    query {
      me {
        id
        email
        displayName
        avatarUrl
        isPlatformAdmin
      }
    }
    """
  end

  defp update_profile_query(display_name, avatar_url) do
    avatar_arg =
      if avatar_url do
        "avatarUrl: \"#{avatar_url}\""
      else
        ""
      end

    """
    mutation {
      updateProfile(input: { displayName: "#{display_name}" #{avatar_arg} }) {
        id
        email
        displayName
        avatarUrl
        isPlatformAdmin
      }
    }
    """
  end
end
