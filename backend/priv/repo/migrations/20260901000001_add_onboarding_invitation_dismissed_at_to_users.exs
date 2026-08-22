defmodule Cgc2046.Repo.Migrations.AddOnboardingInvitationDismissedAtToUsers do
  use Ecto.Migration

  # CONTRIBUTING §4：幂等（*_if_not_exists / *_if_exists 守卫）+ 可逆（显式 down）
  def up do
    alter table(:users) do
      add_if_not_exists :onboarding_invitation_dismissed_at, :utc_datetime
    end
  end

  def down do
    alter table(:users) do
      remove_if_exists :onboarding_invitation_dismissed_at, :utc_datetime
    end
  end
end
