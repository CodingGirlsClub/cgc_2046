defmodule Cgc2046.Repo.Migrations.MakeExpiresAtNullable do
  @moduledoc """
  expires_at 在 add_invitations 中已是 nullable，此 migration 的 up 为幂等确认。
  down 不恢复 NOT NULL：resource 已 allow_nil?: true，收紧约束与定义矛盾，
  且存在 NULL 行时 PG NOT NULL violation 会 crash rollback。
  """

  use Ecto.Migration

  def up do
    alter table(:invitations) do
      modify :expires_at, :utc_datetime, null: true
    end
  end

  def down do
    :ok
  end
end
