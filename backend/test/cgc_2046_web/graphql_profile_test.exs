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
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    # token 由后端 before_send 写 httpOnly cookie，从 Set-Cookie 头提取
    token = conn.resp_cookies["cgc_token"].value
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

    test "me returns P1 extended profile fields (location/about/skills/visibility/memberNumber/joinedAt)" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res = graphql_post(build_conn(), me_query(), token)

      assert %{
               "data" => %{
                 "me" => %{
                   "location" => location,
                   "about" => about,
                   "skills" => skills,
                   "visibility" => visibility,
                   "memberNumber" => member_number,
                   "joinedAt" => joined_at
                 }
               }
             } = res

      assert location == nil
      assert about == nil
      assert skills == []
      assert visibility == "only_me"
      assert is_binary(member_number)
      assert String.starts_with?(member_number, "CGC-")
      assert is_binary(joined_at)
    end

    test "regular user me reflects profile updates" do
      _user = register_user(@user_email, @password)
      token = sign_in_token(@user_email, @password)

      res = graphql_post(build_conn(), me_query(), token)
      assert %{"data" => %{"me" => %{"isPlatformAdmin" => false}}} = res
    end

    test "me returns default uiThemePreference (dark) for a new user (U3)" do
      _user = register_user(@user_email, @password)
      token = sign_in_token(@user_email, @password)

      res = graphql_post(build_conn(), me_query(), token)
      assert %{"data" => %{"me" => %{"uiThemePreference" => "dark"}}} = res
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

    test "updateProfile persists P1 extended fields (location/about/skills/visibility)" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateProfile(input: {
              displayName: "阿麦"
              location: "上海"
              about: "关注社区学习与 AI 教育。"
              skills: ["AI 教育", "课程设计", "Elixir"]
              visibility: "workspace"
            }) {
              id
              location
              about
              skills
              visibility
            }
          }
          """,
          token
        )

      assert %{
               "data" => %{
                 "updateProfile" => %{
                   "location" => "上海",
                   "about" => "关注社区学习与 AI 教育。",
                   "skills" => ["AI 教育", "课程设计", "Elixir"],
                   "visibility" => "workspace"
                 }
               }
             } = res

      # me 反映更新
      res = graphql_post(build_conn(), me_query(), token)

      assert %{
               "data" => %{
                 "me" => %{
                   "location" => "上海",
                   "about" => "关注社区学习与 AI 教育。",
                   "skills" => ["AI 教育", "课程设计", "Elixir"],
                   "visibility" => "workspace"
                 }
               }
             } = res
    end

    test "updateProfile can clear optional fields with explicit null" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      # 先写入
      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateProfile(input: {
              displayName: "阿麦"
              location: "上海"
              about: "简介"
              skills: ["Elixir"]
            }) { id location about skills }
          }
          """,
          token
        )

      assert %{"data" => %{"updateProfile" => %{"location" => "上海"}}} = res

      # 显式 null 清空
      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateProfile(input: {
              displayName: "阿麦"
              location: null
              about: null
              skills: null
            }) { id location about skills }
          }
          """,
          token
        )

      assert %{
               "data" => %{
                 "updateProfile" => %{"location" => nil, "about" => nil, "skills" => nil}
               }
             } = res
    end

    test "updateProfile accepts base64 data URL avatar (image/png)" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      # 1x1 透明 PNG data URL
      data_url =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

      res = graphql_post(build_conn(), update_profile_query("阿麦", data_url), token)
      assert %{"data" => %{"updateProfile" => %{"avatarUrl" => ^data_url}}} = res
    end

    test "updateProfile rejects non-image data URL avatar" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      data_url = "data:text/plain;base64,aGVsbG8="

      res = graphql_post(build_conn(), update_profile_query("阿麦", data_url), token)
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "MIME"))
    end

    test "updateProfile rejects oversized data URL avatar" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      huge = "data:image/png;base64," <> String.duplicate("A", 3_000_100)

      res = graphql_post(build_conn(), update_profile_query("阿麦", huge), token)
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "too large"))
    end

    test "updateProfile rejects non-URL/non-data avatar value" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res = graphql_post(build_conn(), update_profile_query("阿麦", "not-a-url"), token)
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "data URL or http(s) URL"))
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

  describe "setUiTheme mutation (U3 theme persistence)" do
    test "persists theme preference and me reflects it (dark/light)" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      # 切到 light
      res = graphql_post(build_conn(), set_ui_theme_query("light"), token)
      assert %{"data" => %{"setUiTheme" => %{"uiThemePreference" => "light"}}} = res

      # me 反映
      res = graphql_post(build_conn(), me_query(), token)
      assert %{"data" => %{"me" => %{"uiThemePreference" => "light"}}} = res

      # 切回 dark
      res = graphql_post(build_conn(), set_ui_theme_query("dark"), token)
      assert %{"data" => %{"setUiTheme" => %{"uiThemePreference" => "dark"}}} = res
    end

    test "rejects invalid theme value (must be dark or light)" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res = graphql_post(build_conn(), set_ui_theme_query("purple"), token)
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "must be dark or light"))
    end

    test "anonymous is unauthorized" do
      res = graphql_post(build_conn(), set_ui_theme_query("dark"))
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "user cannot set theme for another user via direct Ash action (policy: self only)" do
      admin = admin_user()
      _user = register_user(@user_email, @password)

      user =
        Ash.read_one!(
          Ash.Query.filter(User, email == ^@user_email),
          authorize?: false,
          domain: Cgc2046.GlobalApi
        )

      # 普通用户尝试改平台管理员的主题：policy 应拒绝（id != actor.id）
      result =
        admin
        |> Ash.Changeset.for_update(:set_ui_theme, %{ui_theme_preference: "light"})
        |> Ash.update(actor: user)

      assert {:error, error} = result
      assert Exception.message(Ash.Error.to_error_class(error)) =~ "forbidden"
    end
  end

  defp set_ui_theme_query(theme) do
    """
    mutation {
      setUiTheme(input: { uiThemePreference: "#{theme}" }) {
        id
        uiThemePreference
      }
    }
    """
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
        location
        about
        skills
        visibility
        memberNumber
        joinedAt
        uiThemePreference
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
        location
        about
        skills
        visibility
        memberNumber
        joinedAt
      }
    }
    """
  end
end
