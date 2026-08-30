defmodule Cgc2046.Repo.Migrations.AddVersionToCurriculumOutputs do
  use Ecto.Migration

  @doc """
  role-agent-journeys-v2 S4（R9/R10 草稿乐观并发）：

  - `curriculum_outputs.version`：课程草稿乐观并发版本，首存 1、每次成功写入 +1
    （`upsert_condition(version == base_version)` 单语句 check-and-write +
    `atomic_update(version + 1)`）；存量草稿行视为已存过一版，backfill 1
    （客户端重读即以 1 为 base_version）。

  CONTRIBUTING §4：幂等（add_if_not_exists）+ 可逆（显式 down）。
  """
  def up do
    alter table(:curriculum_outputs) do
      add_if_not_exists :version, :bigint, null: false, default: 1
    end
  end

  def down do
    alter table(:curriculum_outputs) do
      remove_if_exists :version, :bigint
    end
  end
end
