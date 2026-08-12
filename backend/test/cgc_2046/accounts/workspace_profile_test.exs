defmodule Cgc2046.Accounts.WorkspaceProfileTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.WorkspaceProfile
  alias Cgc2046.AccountsFixtures, as: Fixtures

  require Ash.Query

  # 建 WorkspaceProfile（模拟注册/迁移回填的 authorize?: false 建）
  defp create_profile(workspace, user) do
    assert {:ok, profile} =
             WorkspaceProfile
             |> Ash.Changeset.for_create(:create, %{user_id: user.id})
             |> Ash.create(tenant: workspace.id, authorize?: false)

    profile
  end

  describe "WorkspaceProfile resource (ADR-0004)" do
    test "identity: unique per (workspace_id, user_id)" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("wsp-member")
      Fixtures.add_member(ws, member)
      create_profile(ws, member)

      # 同一 ws 重复建 → unique 冲突
      assert {:error, %Ash.Error.Invalid{}} =
               WorkspaceProfile
               |> Ash.Changeset.for_create(:create, %{user_id: member.id})
               |> Ash.create(tenant: ws.id, authorize?: false)
    end

    test "defaults: visibility only_me, theme dark, skills []" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("wsp-member")
      Fixtures.add_member(ws, member)

      profile = create_profile(ws, member)
      assert profile.visibility == :only_me
      assert profile.ui_theme_preference == "dark"
      assert profile.skills == []
      assert is_nil(profile.avatar_url)
    end

    test "update_profile accepts profile fields (own profile, member)" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("wsp-member")
      Fixtures.add_member(ws, member)
      profile = create_profile(ws, member)

      assert {:ok, updated} =
               profile
               |> Ash.Changeset.for_update(:update_profile, %{
                 avatar_url: "https://example.com/avatar.png",
                 location: "杭州",
                 about: "简介",
                 skills: ["TS", "React"],
                 visibility: :public
               })
               |> Ash.update(tenant: ws.id, actor: member, authorize?: false)

      assert updated.avatar_url == "https://example.com/avatar.png"
      assert updated.location == "杭州"
      assert updated.about == "简介"
      assert updated.skills == ["TS", "React"]
      assert updated.visibility == :public
    end

    test "set_ui_theme only accepts dark|light" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("wsp-member")
      Fixtures.add_member(ws, member)
      profile = create_profile(ws, member)

      assert {:ok, updated} =
               profile
               |> Ash.Changeset.for_update(:set_ui_theme, %{ui_theme_preference: "light"})
               |> Ash.update(tenant: ws.id, actor: member, authorize?: false)

      assert updated.ui_theme_preference == "light"

      assert {:error, %Ash.Error.Invalid{}} =
               profile
               |> Ash.Changeset.for_update(:set_ui_theme, %{ui_theme_preference: "blue"})
               |> Ash.update(tenant: ws.id, actor: member, authorize?: false)
    end

    test "avatar validation: non-data/http URL rejected" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("wsp-member")
      Fixtures.add_member(ws, member)
      profile = create_profile(ws, member)

      assert {:error, %Ash.Error.Invalid{}} =
               profile
               |> Ash.Changeset.for_update(:update_profile, %{avatar_url: "not-a-url"})
               |> Ash.update(tenant: ws.id, actor: member, authorize?: false)
    end

    test "anonymous cannot read any profile" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("wsp-member")
      Fixtures.add_member(ws, member)
      _profile = create_profile(ws, member)

      assert {:ok, []} =
               WorkspaceProfile
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: ws.id)
    end
  end

  describe "visibility read authorization (ADR-0004)" do
    test "only_me: only the owner can read" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("wsp-member")
      outsider = Fixtures.register_user("wsp-outsider")
      Fixtures.add_member(ws, member)
      profile = create_profile(ws, member)

      # 本人可读
      assert {:ok, [found]} =
               WorkspaceProfile
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^profile.id)
               |> Ash.read(tenant: ws.id, actor: member)

      assert found.id == profile.id

      # 同 ws 其他成员（非 owner）不可读 only_me
      assert {:ok, []} =
               WorkspaceProfile
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^profile.id)
               |> Ash.read(tenant: ws.id, actor: admin)

      # 非成员不可读
      assert {:ok, []} =
               WorkspaceProfile
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^profile.id)
               |> Ash.read(tenant: ws.id, actor: outsider)
    end

    test "workspace visibility: only target workspace members can read" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws1 = Fixtures.create_workspace(admin, %{slug: "wsp-vis-ws1"})
      ws2 = Fixtures.create_workspace(admin, %{slug: "wsp-vis-ws2"})
      member = Fixtures.register_user("wsp-member")
      Fixtures.add_member(ws1, member)
      Fixtures.add_member(ws2, member)
      profile = create_profile(ws1, member)

      # 设为 workspace 可见
      assert {:ok, _} =
               profile
               |> Ash.Changeset.for_update(:update_profile, %{visibility: :workspace})
               |> Ash.update(tenant: ws1.id, actor: member, authorize?: false)

      # 同 ws1 成员可读
      assert {:ok, [found]} =
               WorkspaceProfile
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^profile.id)
               |> Ash.read(tenant: ws1.id, actor: admin)

      assert found.id == profile.id

      # ws2 的成员（非目标 workspace）不可读——目标 workspace 语义
      other_member = Fixtures.register_user("wsp-ws2-member")
      Fixtures.add_member(ws2, other_member)

      assert {:ok, []} =
               WorkspaceProfile
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^profile.id)
               |> Ash.read(tenant: ws2.id, actor: other_member)
    end

    test "public visibility: any logged-in user can read" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("wsp-member")
      outsider = Fixtures.register_user("wsp-outsider")
      Fixtures.add_member(ws, member)
      profile = create_profile(ws, member)

      assert {:ok, _} =
               profile
               |> Ash.Changeset.for_update(:update_profile, %{visibility: :public})
               |> Ash.update(tenant: ws.id, actor: member, authorize?: false)

      # 非成员但登录用户可读（跨 ws 查询需在正确 tenant 下）
      assert {:ok, [found]} =
               WorkspaceProfile
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^profile.id)
               |> Ash.read(tenant: ws.id, actor: outsider)

      assert found.id == profile.id
    end
  end

  describe "write authorization" do
    test "non-member cannot update profile in a workspace" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)
      outsider = Fixtures.register_user("wsp-outsider")
      profile = create_profile(ws, admin)

      # outsider 非该 ws 成员（authorize 路径下被 ActorIsWorkspaceMember 拒绝）
      assert {:error, _} =
               profile
               |> Ash.Changeset.for_update(:update_profile, %{about: "hack"})
               |> Ash.update(tenant: ws.id, actor: outsider)
    end

    test "member in one workspace cannot update profile in another" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws1 = Fixtures.create_workspace(admin, %{slug: "wsp-write-ws1"})
      ws2 = Fixtures.create_workspace(admin, %{slug: "wsp-write-ws2"})
      member = Fixtures.register_user("wsp-member")
      Fixtures.add_member(ws1, member)
      profile_ws2 = create_profile(ws2, admin)

      # member 是 ws1 成员但非 ws2 成员 → 不可改 ws2 的 admin 档案
      assert {:error, _} =
               profile_ws2
               |> Ash.Changeset.for_update(:update_profile, %{about: "hack"})
               |> Ash.update(tenant: ws2.id, actor: member)
    end

    test "own profile in member workspace is updatable through authorization" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("wsp-member")
      Fixtures.add_member(ws, member)
      profile = create_profile(ws, member)

      assert {:ok, updated} =
               profile
               |> Ash.Changeset.for_update(:update_profile, %{about: "成员简介"})
               |> Ash.update(tenant: ws.id, actor: member)

      assert updated.about == "成员简介"
    end

    test "same-workspace member cannot update another member's profile (review HIGH-1 regression)" do
      admin = Fixtures.platform_admin("wsp-admin")
      ws = Fixtures.create_workspace(admin)

      member_a = Fixtures.register_user("wsp-a")
      member_b = Fixtures.register_user("wsp-b")

      Fixtures.add_member(ws, member_a)
      Fixtures.add_member(ws, member_b)
      profile_a = create_profile(ws, member_a)

      # member_b 与 member_a 同属 ws，但不是 profile_a 的本人 → forbid_unless OwnWorkspaceProfile 拦截
      assert {:error, _} =
               profile_a
               |> Ash.Changeset.for_update(:update_profile, %{about: "hack"})
               |> Ash.update(tenant: ws.id, actor: member_b)
    end
  end
end
