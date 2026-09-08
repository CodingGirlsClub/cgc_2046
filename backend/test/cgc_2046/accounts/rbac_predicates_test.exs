defmodule Cgc2046.Accounts.RbacPredicatesTest do
  @moduledoc """
  `Rbac.manage?/2` 与 `Rbac.staff?/2` 角色谓词契约（2026-09-08 架构评审候选①）：
  取代 21 份工具内私有 authorize 拷贝的判定内核，钉死两族角色集语义。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.AccountsFixtures, as: Fixtures

  describe "manage?/2 与 staff?/2" do
    test "角色矩阵：owner/admin 双 true，tutor 仅 staff?，其余成员与非成员双 false" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()

      admin = Fixtures.register_user("rbac-pred-admin")
      Fixtures.add_member(workspace, admin, [:admin])

      tutor = Fixtures.register_user("rbac-pred-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      learner = Fixtures.register_user("rbac-pred-learner")
      Fixtures.add_member(workspace, learner, [:learner])

      outsider = Fixtures.register_user("rbac-pred-outsider")

      assert Rbac.manage?(owner, workspace.id)
      assert Rbac.manage?(admin, workspace.id)
      refute Rbac.manage?(tutor, workspace.id)
      refute Rbac.manage?(learner, workspace.id)
      refute Rbac.manage?(member, workspace.id)
      refute Rbac.manage?(outsider, workspace.id)

      assert Rbac.staff?(owner, workspace.id)
      assert Rbac.staff?(admin, workspace.id)
      assert Rbac.staff?(tutor, workspace.id)
      refute Rbac.staff?(learner, workspace.id)
      refute Rbac.staff?(member, workspace.id)
      refute Rbac.staff?(outsider, workspace.id)
    end

    test "跨租户：A 台 owner 在 B 台无双判定" do
      a = Fixtures.workspace_with_member()
      b = Fixtures.workspace_with_member()

      assert Rbac.manage?(a.owner, a.workspace.id)
      refute Rbac.manage?(a.owner, b.workspace.id)
      refute Rbac.staff?(a.owner, b.workspace.id)
    end
  end
end
