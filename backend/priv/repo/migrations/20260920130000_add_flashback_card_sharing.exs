defmodule Cgc2046.Repo.Migrations.AddFlashbackCardSharing do
  @moduledoc """
  卡片分享链接（#771）——flashback_people 两个新列：

  - `card_share_slug`：服务端铸的 24 字节随机十六进制标识（48 字符），
    **铸出即不可变**；唯一索引是碰撞最后防线（identity :unique_card_share_slug
    推导名 `flashback_people_unique_card_share_slug_index`，identity 索引名
    守卫会校验存在性与唯一性）；
  - `card_share_enabled_at`：分享开关（置位 = 链接可解析；清空 = 关闭，
    slug 保留以便重开复用同号）。

  两列皆 nullable 无默认、**无回填**：存量档案 `card_share_slug IS NULL` ⇒
  分享从未开启，公开投影直接 nil（fail-closed），旧客户端零感知。

  `card_share_slug` 的索引与 `public_slug` 同为**部分唯一**语义由
  `nils_distinct?` 默认值承担（多行 NULL 互不冲突），故直接建普通唯一索引。

  表为 U1 新建的闪念间档案表（历史死数据导入，非高并发表），不涉
  `concurrently` 活表纪律。
  """

  use Ecto.Migration

  def change do
    alter table(:flashback_people) do
      add(:card_share_slug, :text)
      add(:card_share_enabled_at, :utc_datetime_usec)
    end

    create(
      unique_index(:flashback_people, [:card_share_slug],
        name: :flashback_people_unique_card_share_slug_index
      )
    )
  end
end
