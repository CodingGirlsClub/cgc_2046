defmodule Cgc2046.Notifications.Notification do
  @moduledoc "用户私有的系统接受通知快照，不是渠道送达回执。"
  use Ash.Resource,
    # The primary read intentionally protects GraphQL's mutation pre-read too.
    primary_read_warning?: false,
    domain: Cgc2046.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGraphql.Resource]

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:user_id, :uuid, allow_nil?: false)
    attribute(:type, :string, allow_nil?: false, public?: true)
    attribute(:payload, :map, allow_nil?: false)
    attribute(:deep_link, :string, public?: true)
    attribute(:read_at, :utc_datetime_usec, public?: true)
    create_timestamp(:inserted_at, public?: true)
  end

  calculations do
    calculate(:title, :string, expr(payload["title"]), public?: true, allow_nil?: false)
    calculate(:body, :string, expr(payload["body"]), public?: true, allow_nil?: false)
  end

  actions do
    read :read do
      primary?(true)
      filter(expr(user_id == ^actor(:id) and inserted_at > ago(30, :day)))
      prepare(build(sort: [inserted_at: :desc, id: :asc]))
      pagination(keyset?: true, required?: false, default_limit: 20, max_page_size: 50)
    end

    read :retention do
      description("Internal purge selection; never exposed to GraphQL")
    end

    create :record do
      accept([])
    end

    update :mark_read do
      accept([])
      change(atomic_update(:read_at, expr(if(is_nil(read_at), now(), read_at))))
      # A record may expire between GraphQL's read-before-write and this UPDATE.
      change(filter(expr(inserted_at > ago(30, :day))))
    end

    destroy :purge do
      accept([])
    end
  end

  policies do
    policy action_type([:read, :update]) do
      forbid_if(actor_absent())
      authorize_if(expr(user_id == ^actor(:id)))
    end
  end

  relationships do
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false, allow_nil?: false)
  end

  postgres do
    table("notifications")
    repo(Cgc2046.Repo)

    references do
      reference(:user, on_delete: :delete)
    end

    custom_indexes do
      index([:user_id, "inserted_at DESC", :id], name: "notifications_user_feed_index")
      index([:inserted_at], name: "notifications_retention_index")
    end
  end

  graphql do
    type(:notification)
    derive_filter?(false)
    derive_sort?(false)

    queries do
      list(:notification_feed, :read)
    end

    mutations do
      update(:mark_notification_read, :mark_read)
    end
  end
end
