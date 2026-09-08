defmodule Cgc2046.Repo.Migrations.AlignSlugIdentitySnapshots do
  @moduledoc """
  Snapshot 追认迁移（no-op）。

  courses/events 的 slug 全局唯一索引已由 squash baseline
  （20260901000000_squash_baseline.exs :1285/:1291）手工创建，但当时未回写
  resource snapshot。本迁移仅把 AshPostgres resource snapshot 对齐到既有 schema，
  up/down 刻意置空：否则既有库会因索引已存在报 42P07；新库由 baseline 建索引后
  本迁移空跑即可。
  """

  use Ecto.Migration

  def up do
  end

  def down do
  end
end
