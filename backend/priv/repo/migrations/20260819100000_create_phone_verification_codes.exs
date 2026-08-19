defmodule Cgc2046.Repo.Migrations.CreatePhoneVerificationCodes do
  @moduledoc """
  plan 002 U3：手机验证码表。

  - code_hash 只存 SHA256(phone <> ":" <> code)，明文码不落库。
  - purpose 枚举用 PG 原生 enum（phone_verification_purpose: login/wechat_bind），
    与 Ash one_of 约束对齐。
  - 消费/作废均为单条原子 UPDATE（WHERE 消费状态 + attempts + expires），
    不依赖应用层锁。
  """

  use Ecto.Migration

  @purpose_values ["login", "wechat_bind"]

  def up do
    execute "CREATE TYPE phone_verification_purpose AS ENUM ('login', 'wechat_bind')",
            "DROP TYPE phone_verification_purpose"

    create table(:phone_verification_codes, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :phone, :text, null: false
      add :code_hash, :text, null: false
      add :purpose, :phone_verification_purpose, null: false
      add :expires_at, :utc_datetime, null: false
      add :attempts_left, :integer, null: false, default: 3
      add :consumed_at, :utc_datetime
      add :send_request_id, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:phone_verification_codes, [:phone, :purpose],
             where: "consumed_at IS NULL",
             name: "phone_verification_codes_active_idx"
           )

    create index(:phone_verification_codes, [:expires_at])
  end

  def down do
    drop table(:phone_verification_codes)

    execute "DROP TYPE IF EXISTS phone_verification_purpose",
            "CREATE TYPE phone_verification_purpose AS ENUM ('login', 'wechat_bind')"
  end
end
