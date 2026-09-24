defmodule Cgc2046.Flashback.WishEndorsement do
  @moduledoc """
  许愿附议（KTD3 U3）：一人一愿一票幂等（`unique_wish_actor`），重复附议或
  「已认领 person 的 user 升级」由 domain 层做归并不双计。

  身份合并：
  - 新登录附议 → `user_id` 写 `users.id`，`actor_key` 生成列自动是 `u:<user_id>`
  - 存量 token-only 附议 → `user_id = NULL`，actor_key 是 `p:<person_id>`
  - 归并规则：domain 层 endorse 时先按 user 认领关系查同 wish 的 p: 行，命中则
    update 该 p: 行为 u:（填 user_id 与表单字段），不新增不双计（KTD3）

  计数不落冗余列（白名单纪律），读出口为投影实时 COUNT。`contribution_types`
  （出钱出力类型）与 `message`（给平台的留言）仅运营可见（U5 admin；公开页
  永不返回）。`notify` 是「requested Echo 通知意愿」仅持久化——后端**不调用**
  Consent.grant（KTD3 授权单源）；发送方按 `notify AND Consent.take` 校验。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:wish_id, :uuid, allow_nil?: false, public?: true, writable?: true)

    # FIX-2（KTD3/KTD9）：viewer（无 person 登录用户）附议 listed 愿望时为 NULL——
    # 身份由 user_id / actor_key 生成列承载；幂等防重靠 (wish_id, actor_key) unique
    attribute(:person_id, :uuid, public?: true, writable?: true)
    attribute(:user_id, :uuid, public?: true, writable?: true)

    attribute(:contribution_types, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true,
      writable?: true
    )

    attribute(:message, :string, public?: true, writable?: true)

    attribute(:notify, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: true
    )

    # 首次接受 Echo 通知任务后置位；这是一次性业务机会，不使用 Oban 的短期 unique 窗口。
    attribute(:echo_notification_used_at, :utc_datetime_usec,
      public?: false,
      writable?: false
    )

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:wish, Cgc2046.Flashback.Wish, attribute_writable?: true)
    belongs_to(:person, Cgc2046.Flashback.Person, attribute_writable?: true)
    belongs_to(:user, Cgc2046.Accounts.User, attribute_writable?: true)
  end

  identities do
    # DB 层 (wish_id, actor_key) 是唯一约束（migration 建）；Ash 层 identity 用
    # (wish_id, person_id) 维持与旧版兼容——domain 层 endorse 会显式做 p:→u:
    # 归并（先查 person 在同 wish 是否已有 p: 行；命中 update 而非 insert）。
    identity(:unique_wish_person, [:wish_id, :person_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:wish_id, :person_id, :user_id, :contribution_types, :message, :notify])
      upsert?(true)
      upsert_identity(:unique_wish_person)
    end

    update :update do
      accept([:user_id, :contribution_types, :message, :notify])
    end
  end

  postgres do
    table("flashback_wish_endorsements")
    repo(Cgc2046.Repo)

    references do
      reference(:wish, on_delete: :delete)
      reference(:person, on_delete: :nothing)
      reference(:user, on_delete: :nothing)
    end
  end
end
