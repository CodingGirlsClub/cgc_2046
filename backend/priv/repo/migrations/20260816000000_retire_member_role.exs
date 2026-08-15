defmodule Cgc2046.Repo.Migrations.RetireMemberRole do
  @moduledoc """
  Plan 017：退役 member 角色标签（一次到位）。

  up（幂等，跨全部租户）：
  1. 删除 `membership_roles` 中指向 `roles.name = 'member'` 的行
  2. 删除 `workflow_step_roles` 中指向 `roles.name = 'member'` 的行
  3. 删除 `roles` 中 `name = 'member'` 的行

  不触碰 learner/tutor/volunteer/owner/admin。

  down：不重建 member 角色行（数据已删不可恢复）。member 退役不回头。
  """

  use Ecto.Migration

  def up do
    execute fn ->
      %{rows: [[membership_role_count]]} =
        Ecto.Adapters.SQL.query!(
          repo(),
          """
          SELECT count(*)
          FROM membership_roles mr
          INNER JOIN roles r ON r.id = mr.role_id
          WHERE r.name = 'member'
          """,
          []
        )

      %{rows: [[step_role_count]]} =
        Ecto.Adapters.SQL.query!(
          repo(),
          """
          SELECT count(*)
          FROM workflow_step_roles sr
          INNER JOIN roles r ON r.id = sr.role_id
          WHERE r.name = 'member'
          """,
          []
        )

      %{rows: [[role_count]]} =
        Ecto.Adapters.SQL.query!(
          repo(),
          "SELECT count(*) FROM roles WHERE name = 'member'",
          []
        )

      IO.puts(
        "retire_member_role: membership_roles=#{membership_role_count} " <>
          "workflow_step_roles=#{step_role_count} roles=#{role_count}"
      )

      Ecto.Adapters.SQL.query!(
        repo(),
        """
        DELETE FROM membership_roles
        WHERE role_id IN (SELECT id FROM roles WHERE name = 'member')
        """,
        []
      )

      Ecto.Adapters.SQL.query!(
        repo(),
        """
        DELETE FROM workflow_step_roles
        WHERE role_id IN (SELECT id FROM roles WHERE name = 'member')
        """,
        []
      )

      Ecto.Adapters.SQL.query!(
        repo(),
        "DELETE FROM roles WHERE name = 'member'",
        []
      )
    end
  end

  def down do
    # member 退役不回头：不重建 Role / MembershipRole / StepRole 行。
    :ok
  end
end
