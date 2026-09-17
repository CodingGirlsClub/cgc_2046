defmodule Cgc2046.Flashback.Token do
  @moduledoc """
  首程链接凭据（KTD2）：SHA256 哈希存储，**明文不落任何持久化载体**——
  签发与发送在同一 outreach worker 内完成（生成→渲染→发送→只落 `token_hash`），
  Oban args 只带 person_id 与批次号。

  生命周期：注册（`claimed_by_user_id` 置位）或删除（`revoked_at` 置位）即作废；
  注册前可反复使用（R1）。重发即重签新 token 且**不吊销旧 token**（作废只发生在
  注册或删除），`replaced_by_id` 记录重签链。人与 token 为一对多（含作废历史）。

  消费面：U2 手写 mutation 经 `Cgc2046.Accounts.TokenCredential.fetch/3`
  （`authorize?: false` + token_hash 精确匹配）定位；本资源无 GraphQL 查询面。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)

    # sha256 hex lower（同 Accounts.TokenCredential.hash/1 单源）。
    attribute(:token_hash, :string, allow_nil?: false, public?: true, writable?: true)

    attribute(:claimed_by_user_id, :uuid, public?: true, writable?: false)
    attribute(:claimed_at, :utc_datetime_usec, public?: true, writable?: false)
    attribute(:revoked_at, :utc_datetime_usec, public?: true, writable?: false)

    # 重签链（重发不吊销旧 token；普通 uuid 列，不设自引用 FK）。
    attribute(:replaced_by_id, :uuid, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:person, Cgc2046.Flashback.Person,
      source_attribute: :person_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  identities do
    identity(:unique_token_hash, [:token_hash])
  end

  postgres do
    table("flashback_tokens")
    repo(Cgc2046.Repo)
  end

  actions do
    defaults([:read])

    # outreach worker 专用（authorize?: false 路径）：hash 由 worker 侧计算传入，
    # 本资源不生成 token（明文只在 worker 内存中存在过）。
    create :create do
      accept([:person_id, :token_hash])
    end

    # 服务端内部更新面（U2 claim / U10 revoke 经 force_change_attribute 落点；
    # 无公开 accept——状态字段只由 tokens.ex / deletion.ex 显式改写）。
    update :update do
      require_atomic?(false)
      accept([])
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([
      :id,
      :person_id,
      :claimed_by_user_id,
      :claimed_at,
      :revoked_at,
      :replaced_by_id
    ])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:create) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end
