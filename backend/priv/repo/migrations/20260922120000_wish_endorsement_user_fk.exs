defmodule Cgc2046.Repo.Migrations.WishEndorsementUserFk do
  @moduledoc """
  wish2 review HS-1b：flashback_wish_endorsements.user_id 补 FK（resource 已声明
  belongs_to :user on_delete: :nothing，migration 20260922010000 当年建了裸列——
  fk_on_delete_guard_test DSL↔DB 双向守卫抓漏）。nothing = confdeltype "a"
  （NO ACTION），与 resource 声明一致。
  """
  use Ecto.Migration

  def up do
    # 不改列型（user_id 被生成列 actor_key 引用——postgres 禁止 ALTER TYPE
    # 于 generated column 依赖列）；仅加 FK 约束：on_delete: :nothing = NO ACTION
    # （resource belongs_to 声明一致；fk_on_delete_guard 期望 confdeltype "a"）。
    execute("""
    ALTER TABLE flashback_wish_endorsements
    ADD CONSTRAINT flashback_wish_endorsements_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id)
    """)
  end

  def down do
    # 回滚为裸列（去约束保数据）
    execute(
      "ALTER TABLE flashback_wish_endorsements DROP CONSTRAINT IF EXISTS flashback_wish_endorsements_user_id_fkey"
    )
  end
end
