defmodule Cgc2046.Repo.Migrations.AddUserProfileExtFields do
  @moduledoc """
  P1 Profile 扩展字段（阶段 1 后端模型扩展）：
  - location：所在地（可编辑，可空）
  - about：个人简介（可编辑，可空）
  - skills：技能标签数组 text[]（可编辑，默认空数组）
  - visibility：资料可见范围（默认 workspace_members）

  幂等：对已存在列跳过（dev 库 / 重复执行安全）。
  member_number / joined_at 为计算字段（不落库），无需迁移。
  """

  use Ecto.Migration

  defp column_exists?(table, column) do
    repo()
    |> Ecto.Adapters.SQL.query!(
      "SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
      [to_string(table), to_string(column)]
    )
    |> then(fn result -> result.num_rows > 0 end)
  end

  def up do
    unless column_exists?(:users, :location) do
      alter table(:users) do
        add :location, :text
      end
    end

    unless column_exists?(:users, :about) do
      alter table(:users) do
        add :about, :text
      end
    end

    unless column_exists?(:users, :skills) do
      alter table(:users) do
        # 允许 null（前端清空技能传 null）；default [] 仅新建用户生效
        add :skills, {:array, :text}, default: []
      end
    end

    unless column_exists?(:users, :visibility) do
      alter table(:users) do
        add :visibility, :text, null: false, default: "workspace_members"
      end
    end
  end

  def down do
    if column_exists?(:users, :visibility) do
      alter table(:users) do
        remove :visibility
      end
    end

    if column_exists?(:users, :skills) do
      alter table(:users) do
        remove :skills
      end
    end

    if column_exists?(:users, :about) do
      alter table(:users) do
        remove :about
      end
    end

    if column_exists?(:users, :location) do
      alter table(:users) do
        remove :location
      end
    end
  end
end
