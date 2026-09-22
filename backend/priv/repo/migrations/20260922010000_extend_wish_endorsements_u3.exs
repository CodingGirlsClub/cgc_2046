defmodule Cgc2046.Repo.Migrations.ExtendWishEndorsementsU3 do
  @moduledoc """
  U3（KTD3）：flashback_wish_endorsements 扩列。

  - `user_id :uuid, null: true`（登录附议的 users.id；token-only 存量为 NULL）
  - `actor_key :text, GENERATED ALWAYS AS (CASE WHEN user_id IS NOT NULL THEN 'u:' || user_id::text ELSE 'p:' || person_id::text END) STORED` —— KTD3 合并两份唯一序号
  - 唯一约束从 `(wish_id, person_id)`（`unique_wish_person`）迁到 `(wish_id, actor_key)`（`unique_wish_actor`）：
    存量 p: 行保留，新登录 u: 行加入；同一 user 的 person 已有 p: 行时由 endorse 函数升级为 u:（U3 服务层规则），非 DB 级 merge。
  - `contribution_types :text[], default '{}'`（KTD3 出力类型，运营可分析；R17）
  - `message :text`（≤500，仅运营可见；R17）
  - `notify :boolean, default false`（Echo 通知意愿；KTD3 授权单源——后端不 grant，发送方 take）
  """
  use Ecto.Migration

  def up do
    alter table(:flashback_wish_endorsements) do
      add(:user_id, :uuid, null: true)
      add(:contribution_types, {:array, :text}, default: [], null: false)
      add(:message, :text, null: true)
      add(:notify, :boolean, default: false, null: false)
    end

    execute("""
    ALTER TABLE flashback_wish_endorsements
    ADD COLUMN actor_key text GENERATED ALWAYS AS (
      CASE
        WHEN user_id IS NOT NULL THEN 'u:' || user_id::text
        ELSE 'p:' || person_id::text
      END
    ) STORED
    """)

    # 保留 person_id unique（Ash upsert identity 兼容层）+ 另加 actor_key unique
    #（KTD3 语义唯一：同人不能既以 p: 又以 u: 附议同一愿望——归并规则在 domain
    # 确保 actor_key 不双计）。
    execute("""
    CREATE UNIQUE INDEX flashback_wish_endorsements_unique_wish_actor_index
      ON flashback_wish_endorsements (wish_id, actor_key)
    """)

    execute("""
    CREATE INDEX flashback_wish_endorsements_wish_id_user_id_index
      ON flashback_wish_endorsements (wish_id, user_id)
      WHERE user_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS flashback_wish_endorsements_wish_id_user_id_index")
    execute("DROP INDEX IF EXISTS flashback_wish_endorsements_unique_wish_actor_index")
    execute("ALTER TABLE flashback_wish_endorsements DROP COLUMN IF EXISTS actor_key")

    alter table(:flashback_wish_endorsements) do
      remove(:notify)
      remove(:message)
      remove(:contribution_types)
      remove(:user_id)
    end
  end
end
