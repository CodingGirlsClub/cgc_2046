defmodule Cgc2046.Flashback.Like do
  @moduledoc """
  金句点赞（R36/R37）：金句墙的涌现排序数据源——一句一票
  （`unique_quote_voter`），重复点赞幂等，取消即删行。

  ## 去重键 `voter_key`

  客户端生成、服务端只校验格式与长度：

  - `u:<user_id>`——登录用户按账号去重（同一账号换设备仍是一票）；
  - `a:<device_uuid>`——路人按设备去重（无需登录，R32 路人可读边界的写侧）。

  格式校验在 `Cgc2046.Flashback.Likes`（本资源只钉非空 + 唯一索引；唯一索引
  是并发的最终防线，同一 voter_key 并发双击只会留下一行）。

  ## 读面

  本资源无 GraphQL 查询面：公开读出口是 `Flashback.Public.quotes/1` 的
  实时 COUNT（**不落冗余计数列**，见 KTD3 白名单纪律），作者侧读出口是
  `AlumniProjection` 的 `quoteStats.likeCount`（按人聚合其全部句）。管理端
  读走 ash_admin。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    # 被赞的单句（R37：点赞按句计数与去重）。
    attribute(:quote_id, :uuid, allow_nil?: false, public?: true, writable?: true)

    attribute(:voter_key, :string, allow_nil?: false, public?: true, writable?: true)

    create_timestamp(:created_at)
  end

  relationships do
    belongs_to(:quote, Cgc2046.Flashback.Quote,
      source_attribute: :quote_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  identities do
    identity(:unique_quote_voter, [:quote_id, :voter_key])
  end

  postgres do
    table("flashback_likes")
    repo(Cgc2046.Repo)

    references do
      reference(:quote, on_delete: :delete)
    end
  end

  actions do
    defaults([:read])

    # flashbackLikeQuote 专用（authorize?: false 路径，公开 mutation）。
    # upsert 承接并发重复点赞：唯一索引冲突即视为「已赞」，不报错也不重复计数。
    create :create do
      accept([:quote_id, :voter_key])
      upsert?(true)
      upsert_identity(:unique_quote_voter)
    end

    # 取消点赞（liked=false）：按 (quote_id, voter_key) 定位后删除，幂等。
    destroy :destroy do
      primary?(true)
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :quote_id, :voter_key, :created_at])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type([:create, :destroy]) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end
