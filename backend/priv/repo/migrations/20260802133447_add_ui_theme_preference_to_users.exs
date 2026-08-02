defmodule Cgc2046.Repo.Migrations.AddUiThemePreferenceToUsers do
  @moduledoc """
  U3 主题偏好字段：ui_theme_preference（dark | light，默认 dark）。
  服务端持久化用户 UI 主题偏好，用于跨设备同步。

  幂等：对已存在列跳过（dev 库 / 重复执行安全）。
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
    unless column_exists?(:users, :ui_theme_preference) do
      alter table(:users) do
        add :ui_theme_preference, :string, null: false, default: "dark"
      end
    end
  end

  def down do
    if column_exists?(:users, :ui_theme_preference) do
      alter table(:users) do
        remove :ui_theme_preference
      end
    end
  end
end
