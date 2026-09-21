defmodule Cgc2046.Repo.Migrations.CreateFlashbackLikesAndQuoteHidden do
  use Ecto.Migration

  # R36 点赞：金句墙的涌现排序数据源。
  #   - voter_key 格式 `u:<user_id>`（登录用户按账号去重）/ `a:<device_uuid>`
  #     （路人按设备去重）——服务端只校验格式与长度上限，去重靠唯一索引；
  #   - (person_id, voter_key) 唯一索引即 identity 推导名
  #     （identity_index_guard 惯例，同 flashback_todays）。
  # 另：R38 平台下线开关 `flashback_quote_licenses.hidden_at`（admin 写，quotes 过滤）。
  def change do
    create table(:flashback_likes, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      # 被赞金句的作者（金句以人唯一：quote_licenses 有 unique_person）。
      add(:person_id, references(:flashback_people, type: :uuid, column: :id), null: false)

      add(:voter_key, :text, null: false)

      # 资源侧是 create_timestamp(:created_at)（一票一行，无 update 语义）
      add(:created_at, :utc_datetime_usec, null: false)
    end

    # 一人一句一票（重复点赞幂等；取消后重赞回到同一行）。
    # person_id 单独索引不另建：本唯一索引的前导列已覆盖 person_id 查询。
    create(
      unique_index(:flashback_likes, [:person_id, :voter_key],
        name: :flashback_likes_unique_person_voter_index
      )
    )

    # 按投票者查（「我赞过哪些」/清理）：voter_key 非任何索引前导列，单独建。
    create(index(:flashback_likes, [:voter_key]))

    # R38：内容责任边界的管理端下线开关（人工撤下红线问题，无审核流水线）。
    alter table(:flashback_quote_licenses) do
      add(:hidden_at, :utc_datetime_usec)
    end
  end
end
