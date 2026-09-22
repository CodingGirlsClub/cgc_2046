defmodule Cgc2046.Repo.Migrations.WishEndorsementPersonNullable do
  @moduledoc """
  wish2 审计 FIX-2（KTD3/KTD9）：flashback_wish_endorsements.person_id 放宽
  nullable——viewer（无 person 的登录用户）对 listed 愿望附议时 person_id 为
  NULL，身份由 user_id / actor_key（u:<user_id>）承载。

  存量行不受影响（person_id 全部有值）。幂等防重交由既有
  (wish_id, actor_key) unique index：viewer 重复附议走 domain 层
  「查 u: 行 → UPDATE」幂等路径。
  """
  use Ecto.Migration

  def up do
    execute("ALTER TABLE flashback_wish_endorsements ALTER COLUMN person_id DROP NOT NULL")
  end

  def down do
    # 回滚安全性：存在 NULL 行时先删（viewer 附议行），再收紧
    execute("DELETE FROM flashback_wish_endorsements WHERE person_id IS NULL")
    execute("ALTER TABLE flashback_wish_endorsements ALTER COLUMN person_id SET NOT NULL")
  end
end
