defmodule Cgc2046.Flashback.OutreachLink do
  @moduledoc """
  闪念间触达批次级微信 URL Link 缓存（#770）。

  一个 batch 只保留一条：URL Link 最长 30 天，`expires_at` 早于安全余量
  （now + 1h）即重生成覆盖（upsert 幂等照 `Cgc2046.Miniprogram.ShareScheme`
  先例）。纯服务端缓存（worker authorize?: false 路径读写），无入口可写；
  明文 token 只在发送时以 `?cq=` 拼在链接后，不入本表。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    # 批次号（outreach worker 入队时 Oban args 携带的同一 string）。
    attribute(:batch, :string, allow_nil?: false)
    attribute(:url_link, :string, allow_nil?: false)
    attribute(:expires_at, :utc_datetime, allow_nil?: false)
    create_timestamp(:inserted_at)
  end

  identities do
    identity(:unique_batch, [:batch])
  end

  actions do
    create :create do
      accept([:batch, :url_link, :expires_at])
      upsert?(true)
      upsert_identity(:unique_batch)
      upsert_fields([:url_link, :expires_at])
    end

    defaults([:read])
  end

  postgres do
    table("flashback_outreach_links")
    repo(Cgc2046.Repo)
  end

  policies do
    policy always() do
      forbid_if(always())
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :batch, :url_link, :expires_at, :inserted_at])
  end
end
