defmodule Cgc2046.Flashback.WishEcho do
  @moduledoc """
  平台为已挂树愿望发布的纯文本回响。状态只能通过 `WishEchoes` 的显式领域
  操作迁移；GraphQL 不暴露 Ash 的通用 create/update/destroy 动作。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:wish_id, :uuid, allow_nil?: false, public?: true)
    attribute(:content, :string, allow_nil?: false, public?: true)

    attribute(:status, :string,
      allow_nil?: false,
      default: "draft",
      public?: true,
      writable?: false
    )

    attribute(:published_at, :utc_datetime_usec, public?: true)
    attribute(:corrected_at, :utc_datetime_usec, public?: true)
    attribute(:revoked_at, :utc_datetime_usec, public?: true)

    # 保留发布时管理员的稳定 UUID 供审计；不建立 users 外键，避免删除账号时抹去
    # 历史归属或阻塞账号生命周期。
    attribute(:published_by_user_id, :uuid, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:wish, Cgc2046.Flashback.Wish, attribute_writable?: true)
  end

  actions do
    defaults([:read])

    create :create_draft do
      accept([:wish_id, :content])
    end

    update :update_draft do
      accept([:content])
    end

    update :publish do
      accept([:published_at, :published_by_user_id])
      change(set_attribute(:status, "published"))
    end

    update :correct do
      accept([:content, :corrected_at])
      change(set_attribute(:status, "corrected"))
    end

    update :revoke do
      accept([:revoked_at])
      change(set_attribute(:status, "revoked"))
    end
  end

  postgres do
    table("flashback_wish_echoes")
    repo(Cgc2046.Repo)

    references do
      reference(:wish, on_delete: :delete)
    end
  end
end
