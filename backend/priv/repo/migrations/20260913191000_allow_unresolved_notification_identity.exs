defmodule Cgc2046.Repo.Migrations.AllowUnresolvedNotificationIdentity do
  use Ecto.Migration

  def change do
    alter table(:notification_deliveries) do
      modify :platform, :text, null: true
      modify :identity_uid, :text, null: true
    end
  end
end
