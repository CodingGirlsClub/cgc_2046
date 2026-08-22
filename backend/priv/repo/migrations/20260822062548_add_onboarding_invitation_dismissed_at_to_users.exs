defmodule Cgc2046.Repo.Migrations.AddOnboardingInvitationDismissedAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :onboarding_invitation_dismissed_at, :utc_datetime
    end
  end
end
