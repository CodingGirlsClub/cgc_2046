defmodule Cgc2046.RbacTest do
  use ExUnit.Case, async: true

  alias Cgc2046.Accounts.Role
  alias Cgc2046.Rbac

  describe "matrix/0" do
    test "matches the contract artifact (5 roles, G1)" do
      matrix = Rbac.matrix()

      assert length(matrix) == 5
      # 角色枚举断言引用单源（G2 收敛），避免测试与 Role.role_names/0 漂移
      assert Enum.map(matrix, & &1.role) == Role.role_names()
      refute :member in Role.role_names()

      for row <- matrix, row.role in Role.manage_roles() do
        assert row.abilities.view_workspace == true
        assert row.abilities.access_invite_only == true
        assert row.abilities.list_members == true
        assert row.abilities.manage_members == true
        assert row.abilities.assign_roles == true
        assert row.abilities.update_join_policy == true
        assert row.abilities.create_workspace == false
      end

      for role <- [:tutor, :volunteer, :learner] do
        row = Enum.find(matrix, &(&1.role == role))
        assert row.abilities.view_workspace == true
        assert row.abilities.access_invite_only == true
        assert row.abilities.list_members == false
        assert row.abilities.manage_members == false
        assert row.abilities.assign_roles == false
        assert row.abilities.update_join_policy == false
        assert row.abilities.create_workspace == false
      end
    end
  end

  describe "abilities_for/2 (#1 能力接口收敛共享纯函数)" do
    test "role-derived abilities match matrix rows" do
      # owner/admin：全部管理能力 + view/access
      for role <- [:owner, :admin] do
        assert Rbac.abilities_for([role], false) == [
                 :view_workspace,
                 :access_invite_only,
                 :list_members,
                 :manage_members,
                 :assign_roles,
                 :update_join_policy
               ]
      end

      # 成员级角色：仅 view/access
      for role <- [:tutor, :volunteer, :learner] do
        assert Rbac.abilities_for([role], false) == [:view_workspace, :access_invite_only]
      end
    end

    test "multi-role union takes precedence over single roles" do
      assert Rbac.abilities_for([:tutor, :admin], false) == [
               :view_workspace,
               :access_invite_only,
               :list_members,
               :manage_members,
               :assign_roles,
               :update_join_policy
             ]
    end

    test "platform admin flag adds create_workspace and view/access exemption" do
      # 非成员平台管理员（roles 为空）：view/access + update_join_policy 豁免 + create_workspace
      assert Rbac.abilities_for([], true) == [
               :view_workspace,
               :access_invite_only,
               :update_join_policy,
               :create_workspace
             ]

      # 成员平台管理员：全部七项
      assert Rbac.abilities_for([:owner], true) == [
               :view_workspace,
               :access_invite_only,
               :list_members,
               :manage_members,
               :assign_roles,
               :update_join_policy,
               :create_workspace
             ]

      # 非平台管理员：create_workspace 永假（与矩阵一致）
      refute :create_workspace in Rbac.abilities_for([:owner], false)
    end

    test "empty roles (member with no roles) still gets view/access — member semantics" do
      # 成员身份由调用方（calc 的 membership 门）判定；零角色成员仍可访问
      # （与 roles_can? 的成员语义一致：view/access 无条件 true）
      assert Rbac.abilities_for([], false) == [:view_workspace, :access_invite_only]
    end

    test "unions with matrix/0 for every role (single-source consistency)" do
      for row <- Rbac.matrix() do
        expected = for {ability, true} <- row.abilities, do: ability

        # 语义集合一致（matrix 的 map 迭代序 ≠ @abilities 列表序，按集合比较）
        assert Enum.sort(Rbac.abilities_for([row.role], false)) == Enum.sort(expected)
      end
    end
  end
end
