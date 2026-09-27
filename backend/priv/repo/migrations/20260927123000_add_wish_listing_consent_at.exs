defmodule Cgc2046.Repo.Migrations.AddWishListingConsentAt do
  @moduledoc """
  #817：flashback_wishes 加 listing_consent_at——作者挂树授权证据持久化
  （visibility=public AND consent=true 时创建即写入，无论是否待审）。
  admin 放行（approve_wish_listing）的授权不变量依据：仅本列非空的愿望可置
  listed_at（授权不扩大红线）。

  存量回填（漏标优于误标）：
  - listed_at 非空 → 已挂树即已授权，回填 = listed_at；
  - listed nil + hidden 置位 + public 且 hidden_at ≤ inserted_at + 5s
    （创建即待审：FIX-3/P2-1 路径同事务写 hidden_at，毫秒级差）→ 回填 = hidden_at；
  - 其余（admin 曾直接调 mutation hide 未授权愿望的长尾）留 NULL——admin 面
    显示「无授权证据·人工处理」，不放行。
  合并前人工核对（预期 0 行，非 0 行逐条确认是否 admin 手动下架）：
    SELECT id, inserted_at, hidden_at FROM flashback_wishes
    WHERE visibility = 'public' AND listed_at IS NULL
      AND hidden_at IS NOT NULL
      AND hidden_at > inserted_at + interval '5 seconds';
  """
  use Ecto.Migration

  def up do
    alter table(:flashback_wishes) do
      add(:listing_consent_at, :utc_datetime_usec, null: true)
    end

    # 已挂树 → 授权证据 = listed_at（listed_at 仅在 public+consent 写入，无需再限定）
    execute("""
    UPDATE flashback_wishes
    SET listing_consent_at = listed_at
    WHERE listed_at IS NOT NULL
      AND listing_consent_at IS NULL
    """)

    # 创建即待审（同事务写入，时间差毫秒级）→ 授权证据 = hidden_at；
    # 5s 窗口外的（admin 手动 hide 长尾）留 NULL 人工复核
    execute("""
    UPDATE flashback_wishes
    SET listing_consent_at = hidden_at
    WHERE visibility = 'public'
      AND listed_at IS NULL
      AND hidden_at IS NOT NULL
      AND hidden_at <= inserted_at + interval '5 seconds'
      AND listing_consent_at IS NULL
    """)
  end

  def down do
    alter table(:flashback_wishes) do
      remove(:listing_consent_at)
    end
  end
end
