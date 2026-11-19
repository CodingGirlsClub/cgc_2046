defmodule Cgc2046.Repo.Migrations.ValidateWorkspacesCreditPoolNonnegative do
  @moduledoc """
  独立 VALIDATE 迁移（#634）：`workspaces_credit_pool_mc_nonnegative` 在
  建表迁移里以 NOT VALID 上线，这里完成全表校验，避免与 DDL 混在同一窗口。
  """
  use Ecto.Migration

  def up do
    execute("ALTER TABLE workspaces VALIDATE CONSTRAINT workspaces_credit_pool_mc_nonnegative")
  end

  def down do
    execute(
      "ALTER TABLE workspaces DROP CONSTRAINT IF EXISTS workspaces_credit_pool_mc_nonnegative"
    )
  end
end
