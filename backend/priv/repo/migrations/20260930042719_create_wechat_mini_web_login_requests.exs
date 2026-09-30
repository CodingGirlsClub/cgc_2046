defmodule Cgc2046.Repo.Migrations.CreateWechatMiniWebLoginRequests do
  use Ecto.Migration

  def change do
    create table(:wechat_mini_web_login_requests, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :public_code, :text, null: false
      add :browser_proof_hash, :binary, null: false
      add :browser_rate_key, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :user_id, references(:users, type: :uuid, on_delete: :nothing)
      add :expires_at, :utc_datetime, null: false
      add :approved_at, :utc_datetime
      add :consumed_at, :utc_datetime
      add :cancelled_at, :utc_datetime
      add :consumed_jti, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:wechat_mini_web_login_requests, [:public_code],
             name: :wechat_mini_web_login_requests_unique_public_code_index
           )

    create index(:wechat_mini_web_login_requests, [:expires_at])

    create constraint(:wechat_mini_web_login_requests, :mini_web_login_state,
             check:
               "status IN ('pending','approved','consumed','cancelled') AND (status NOT IN ('approved','consumed') OR user_id IS NOT NULL) AND (status <> 'consumed' OR consumed_jti IS NOT NULL)"
           )
  end
end
