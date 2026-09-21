defmodule Cgc2046.Repo.Migrations.AddFlashbackEventArchiveLabel do
  use Ecto.Migration

  def change do
    alter table(:flashback_event_archives) do
      # 长廊场次格叙事短标签（原型 D ia-frame-label）：「六城同日」这类故事话，
      # 不写日期城市（日期城市在 when 行已有）。
      add :label, :string
    end
  end
end
