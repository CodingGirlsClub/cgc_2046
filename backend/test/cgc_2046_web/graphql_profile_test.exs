defmodule Cgc2046Web.GraphqlProfileTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.WorkspaceProfile
  alias Cgc2046.AccountsFixtures, as: Fixtures

  @password Fixtures.password()

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
      signIn(login: "#{email}", password: "#{password}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    token = conn.resp_cookies["cgc_token"].value
    token
  end

  defp ensure_profile(workspace, user, attrs \\ %{}) do
    assert {:ok, profile} =
             WorkspaceProfile
             |> Ash.Changeset.for_create(:create, %{user_id: user.id})
             |> Ash.create(tenant: workspace.id, authorize?: false)

    if attrs != %{} do
      assert {:ok, _} =
               profile
               |> Ash.Changeset.for_update(:update_profile, attrs)
               |> Ash.update(tenant: workspace.id, actor: user, authorize?: false)
    end

    profile
  end

  defp me_query do
    """
    query {
      me {
        id
        email
        displayName
        isPlatformAdmin
        memberNumber
        joinedAt
      }
    }
    """
  end

  describe "me query (ADR-0004 收窄为全局身份)" do
    test "anonymous is unauthorized" do
      res = graphql_post(build_conn(), "query { me { id email } }")
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "returns global identity fields only (no profile fields)" do
      admin = Fixtures.platform_admin("gql-profile-admin")
      token = sign_in_token(admin.email, @password)

      res = graphql_post(build_conn(), me_query(), token)

      assert %{
               "data" => %{
                 "me" => %{
                   "id" => id,
                   "email" => email,
                   "displayName" => display_name,
                   "isPlatformAdmin" => is_platform_admin,
                   "memberNumber" => member_number,
                   "joinedAt" => joined_at
                 }
               }
             } = res

      assert is_binary(id)
      assert email == to_string(admin.email)
      assert display_name == nil
      assert is_platform_admin == true
      assert is_binary(member_number)
      assert String.starts_with?(member_number, "CGC-")
      assert is_binary(joined_at)
    end

    test "me does not expose per-workspace profile fields" do
      admin = Fixtures.platform_admin("gql-profile-admin")
      token = sign_in_token(admin.email, @password)

      res =
        graphql_post(
          build_conn(),
          "{ me { avatarUrl uiThemePreference visibility location } }",
          token
        )

      # 字段不在全局 User type 上 → 报 GraphQL 字段不存在错误
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "Cannot query field"))
    end
  end

  describe "workspaceProfile query (ADR-0004 per-workspace)" do
    test "anonymous is unauthorized" do
      res = graphql_post(build_conn(), "query { workspaceProfile(workspaceId: \"x\") { id } }")
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "returns current user profile in the workspace" do
      admin = Fixtures.platform_admin("gql-profile-admin")
      ws = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("gql-profile-user")
      Fixtures.add_member(ws, user)
      ensure_profile(ws, user, %{location: "杭州", about: "介绍", skills: ["TS"]})
      token = sign_in_token(user.email, @password)

      res =
        graphql_post(
          build_conn(),
          """
          query {
            workspaceProfile(workspaceId: "#{ws.id}") {
              id
              location
              about
              skills
              visibility
              uiThemePreference
              avatarUrl
            }
          }
          """,
          token
        )

      assert %{
               "data" => %{
                 "workspaceProfile" => %{
                   "id" => _id,
                   "location" => "杭州",
                   "about" => "介绍",
                   "skills" => ["TS"],
                   "visibility" => "only_me",
                   "uiThemePreference" => "dark",
                   "avatarUrl" => nil
                 }
               }
             } = res
    end

    test "workspaceProfile is per-workspace (different data in different ws)" do
      admin = Fixtures.platform_admin("gql-profile-admin")
      ws1 = Fixtures.create_workspace(admin)
      ws2 = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("gql-profile-user")
      Fixtures.add_member(ws1, user)
      Fixtures.add_member(ws2, user)
      ensure_profile(ws1, user, %{about: "ws1 简介"})
      ensure_profile(ws2, user, %{about: "ws2 简介"})
      token = sign_in_token(user.email, @password)

      res1 =
        graphql_post(
          build_conn(),
          "query { workspaceProfile(workspaceId: \"#{ws1.id}\") { about } }",
          token
        )

      assert res1["data"]["workspaceProfile"]["about"] == "ws1 简介"

      res2 =
        graphql_post(
          build_conn(),
          "query { workspaceProfile(workspaceId: \"#{ws2.id}\") { about } }",
          token
        )

      assert res2["data"]["workspaceProfile"]["about"] == "ws2 简介"
    end
  end

  describe "updateWorkspaceProfile mutation (ADR-0004)" do
    test "updates own profile in workspace" do
      admin = Fixtures.platform_admin("gql-profile-admin")
      ws = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("gql-profile-user")
      Fixtures.add_member(ws, user)
      ensure_profile(ws, user)
      token = sign_in_token(user.email, @password)

      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateWorkspaceProfile(
              workspaceId: "#{ws.id}"
              input: { avatarUrl: "https://example.com/a.png", location: "深圳", about: "新简介", skills: ["React"], visibility: "public" }
            ) {
              avatarUrl
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
                 "updateWorkspaceProfile" => %{
                   "avatarUrl" => "https://example.com/a.png",
                   "location" => "深圳",
                   "about" => "新简介",
                   "skills" => ["React"],
                   "visibility" => "public"
                 }
               }
             } = res
    end

    test "non-member cannot update profile in a workspace" do
      admin = Fixtures.platform_admin("gql-profile-admin")
      ws = Fixtures.create_workspace(admin)

      # outsider 未加入 ws（仅 admin 是成员）；用 outsider 的 token 尝试改 admin 的档案
      outsider = Fixtures.register_user("gql-profile-other")
      ensure_profile(ws, admin)
      token = sign_in_token(outsider.email, @password)

      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateWorkspaceProfile(
              workspaceId: "#{ws.id}"
              input: { about: "hack" }
            ) {
              id
            }
          }
          """,
          token
        )

      # outsider 不是该 ws 成员 → workspaceProfile 查不到自己的档案（policy 拒绝）→ 错误
      assert %{"errors" => errors} = res
      assert errors != []
    end
  end

  describe("updateDisplayName mutation (ADR-0004 全局身份)") do
    test "updates global display name and returns calculation fields" do
      admin = Fixtures.platform_admin("gql-profile-admin")
      token = sign_in_token(admin.email, @password)

      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateDisplayName(displayName: "新全局名") {
              id
              displayName
              memberNumber
              joinedAt
            }
          }
          """,
          token
        )

      assert %{
               "data" => %{
                 "updateDisplayName" => %{
                   "displayName" => "新全局名",
                   "memberNumber" => member_number,
                   "joinedAt" => joined_at
                 }
               }
             } = res

      assert is_binary(member_number)
      assert is_binary(joined_at)
    end
  end

  describe "updateMyLocale mutation (i18n Phase 1)" do
    test "updates locale and returns it on the user type" do
      user = Fixtures.register_user("gql-locale-user")
      token = sign_in_token(user.email, @password)

      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateMyLocale(locale: "en") {
              id
              locale
            }
          }
          """,
          token
        )

      assert %{"data" => %{"updateMyLocale" => %{"locale" => "en"}}} = res
    end

    test "rejects an unsupported locale with a field error" do
      user = Fixtures.register_user("gql-locale-user-2")
      token = sign_in_token(user.email, @password)

      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateMyLocale(locale: "fr") {
              id
              locale
            }
          }
          """,
          token
        )

      assert %{"data" => %{"updateMyLocale" => nil}, "errors" => errors} = res

      assert Enum.any?(errors, fn e ->
               e["code"] == "invalid_attribute" && e["fields"] == ["locale"]
             end)
    end

    test "requires authentication" do
      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateMyLocale(locale: "en") {
              id
            }
          }
          """
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "me query exposes locale" do
      user = Fixtures.register_user("gql-locale-user-3")
      token = sign_in_token(user.email, @password)

      res = graphql_post(build_conn(), "{ me { locale } }", token)
      assert %{"data" => %{"me" => %{"locale" => nil}}} = res

      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            updateMyLocale(locale: "en") {
              locale
            }
          }
          """,
          token
        )

      assert %{"data" => %{"updateMyLocale" => %{"locale" => "en"}}} = res

      res = graphql_post(build_conn(), "{ me { locale } }", token)
      assert %{"data" => %{"me" => %{"locale" => "en"}}} = res
    end
  end

  describe "dismissOnboardingInvitation mutation (首公里 R2)" do
    test "persists dismissal timestamp and me exposes it" do
      user = Fixtures.register_user("gql-dismiss-user")
      token = sign_in_token(user.email, @password)

      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            dismissOnboardingInvitation {
              id
              onboardingInvitationDismissedAt
            }
          }
          """,
          token
        )

      assert %{
               "data" => %{
                 "dismissOnboardingInvitation" => %{
                   "onboardingInvitationDismissedAt" => dismissed_at
                 }
               }
             } = res

      assert is_binary(dismissed_at)

      # R2 数据面：拒绝状态持久化，重查 me 仍在（跨设备一致的服务端来源）
      res =
        graphql_post(
          build_conn(),
          "{ me { onboardingInvitationDismissedAt } }",
          token
        )

      assert %{
               "data" => %{
                 "me" => %{"onboardingInvitationDismissedAt" => ^dismissed_at}
               }
             } = res
    end

    test "requires authentication" do
      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            dismissOnboardingInvitation {
              id
            }
          }
          """
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end
  end

  describe "setWorkspaceTheme mutation (ADR-0004 per-workspace theme)" do
    test "sets theme in a workspace" do
      admin = Fixtures.platform_admin("gql-profile-admin")
      ws = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("gql-profile-user")
      Fixtures.add_member(ws, user)
      ensure_profile(ws, user)
      token = sign_in_token(user.email, @password)

      res =
        graphql_post(
          build_conn(),
          """
          mutation {
            setWorkspaceTheme(
              workspaceId: "#{ws.id}"
              input: { uiThemePreference: "light" }
            ) {
              uiThemePreference
            }
          }
          """,
          token
        )

      assert %{"data" => %{"setWorkspaceTheme" => %{"uiThemePreference" => "light"}}} = res
    end

    test "theme is per-workspace" do
      admin = Fixtures.platform_admin("gql-profile-admin")
      ws1 = Fixtures.create_workspace(admin)
      ws2 = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("gql-profile-user")
      Fixtures.add_member(ws1, user)
      Fixtures.add_member(ws2, user)
      ensure_profile(ws1, user)
      ensure_profile(ws2, user)
      token = sign_in_token(user.email, @password)

      graphql_post(
        build_conn(),
        """
        mutation {
          setWorkspaceTheme(workspaceId: "#{ws1.id}" input: { uiThemePreference: "light" }) {
            uiThemePreference
          }
        }
        """,
        token
      )

      res2 =
        graphql_post(
          build_conn(),
          "query { workspaceProfile(workspaceId: \"#{ws2.id}\") { uiThemePreference } }",
          token
        )

      # ws2 未改 → 仍默认 dark
      assert res2["data"]["workspaceProfile"]["uiThemePreference"] == "dark"
    end
  end

  describe "portfolio CRUD (ADR-0004 per-workspace)" do
    test "create + list + update + delete in a workspace (tenant isolated)" do
      admin = Fixtures.platform_admin("gql-profile-admin")
      ws1 = Fixtures.create_workspace(admin)
      ws2 = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("gql-profile-user")
      Fixtures.add_member(ws1, user)
      Fixtures.add_member(ws2, user)
      token = sign_in_token(user.email, @password)

      # create in ws1
      res_create =
        graphql_post(
          build_conn(),
          """
          mutation {
            createPortfolioItem(workspaceId: "#{ws1.id}" input: { title: "作品A", description: "描述" }) {
              id
              title
              workspaceId
            }
          }
          """,
          token
        )

      assert %{"data" => %{"createPortfolioItem" => %{"title" => "作品A", "workspaceId" => ws1_id}}} =
               res_create

      assert ws1_id == ws1.id
      item_id = res_create["data"]["createPortfolioItem"]["id"]

      # list ws1 有 1 条；ws2 空（tenant 隔离）
      res_list1 =
        graphql_post(
          build_conn(),
          "query { myWorkspacePortfolio(workspaceId: \"#{ws1.id}\") { id title } }",
          token
        )

      assert [%{"id" => ^item_id, "title" => "作品A"}] =
               res_list1["data"]["myWorkspacePortfolio"]

      res_list2 =
        graphql_post(
          build_conn(),
          "query { myWorkspacePortfolio(workspaceId: \"#{ws2.id}\") { id title } }",
          token
        )

      assert res_list2["data"]["myWorkspacePortfolio"] == []

      # update in ws1
      res_update =
        graphql_post(
          build_conn(),
          """
          mutation {
            updatePortfolioItem(id: "#{item_id}" workspaceId: "#{ws1.id}" input: { title: "作品A改名" }) {
              title
            }
          }
          """,
          token
        )

      assert res_update["data"]["updatePortfolioItem"]["title"] == "作品A改名"

      # delete in ws1
      res_del =
        graphql_post(
          build_conn(),
          """
          mutation {
            deletePortfolioItem(id: "#{item_id}" workspaceId: "#{ws1.id}") {
              id
            }
          }
          """,
          token
        )

      assert res_del["data"]["deletePortfolioItem"]["id"] == item_id

      # ws1 现在空
      res_list1_after =
        graphql_post(
          build_conn(),
          "query { myWorkspacePortfolio(workspaceId: \"#{ws1.id}\") { id } }",
          token
        )

      assert res_list1_after["data"]["myWorkspacePortfolio"] == []
    end
  end
end
