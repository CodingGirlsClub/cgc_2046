defmodule Cgc2046.Repo.Migrations.AddUserProfileFields do
  @moduledoc """
  为 users 表添加个人资料字段（#68 A-6-BE Profile API）：
  - display_name：显示名（可为 null，默认以 email 前缀兜底显示）
  - avatar_url：头像 URL（可选）
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
    unless column_exists?(:users, :display_name) do
      alter table(:users) do
        add :display_name, :string
      end
    end

    unless column_exists?(:users, :avatar_url) do
      alter table(:users) do
        add :avatar_url, :string
      end
    end
  end

  def down do
    if column_exists?(:users, :display_name) do
      alter table(:users) do
        remove :display_name
      end
    end

    if column_exists?(:users, :avatar_url) do
      alter table(:users) do
        remove :avatar_url
      end
    end
  end
end
