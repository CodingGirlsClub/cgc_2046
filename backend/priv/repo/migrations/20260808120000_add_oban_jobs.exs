defmodule Cgc2046.Repo.Migrations.AddObanJobs do
  @moduledoc """
  0C：引入 Oban（Apache-2.0，合规门已审）——审批超时主动调度与 48h 提醒 cron 的
  PG-backed job 表。纯新增表，可逆（down 全量回滚 Oban 版本化迁移）。
  """

  use Ecto.Migration

  def up, do: Oban.Migrations.up()

  def down, do: Oban.Migrations.down()
end
