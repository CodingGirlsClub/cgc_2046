defmodule Cgc2046.Repo.Migrations.CreateWechatLoginTickets do
  @moduledoc """
  plan 002 U4：微信扫码登录票据表。

  - state 唯一（前端会话标识，单次使用）
  - status 迁移全部原子 UPDATE（WHERE status + expires_at > now()）
  - access_token 敏感（绑定完成前凭证）
  """
  use Ecto.Migration

  def up do
    create table(:wechat_login_tickets, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :state, :text, null: false
      add :openid, :text
      add :unionid, :text
      add :access_token, :text
      add :status, :text, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:wechat_login_tickets, [:state])

    create index(:wechat_login_tickets, [:expires_at])
  end

  def down do
    drop table(:wechat_login_tickets)
  end
end
