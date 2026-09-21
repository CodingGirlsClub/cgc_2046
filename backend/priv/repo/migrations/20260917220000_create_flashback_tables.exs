defmodule Cgc2046.Repo.Migrations.CreateFlashbackTables do
  @moduledoc """
  闪念间（In a Flash）域十表（U1，KTD1）。死数据 + token 凭据 + 行为事件：

  - 唯一索引名与 resource identity 推导名逐字对齐（#611 守卫：`<table>_<identity>_index`）；
  - FK 不带 on_delete（与 snapshot 一致：档案删除走 U10 显式级联，不依赖 DB 级联）；
  - user_id / event_id / token_id / claimed_by_user_id / replaced_by_id 为裸 uuid
  （跨域/自引用引用不设 relationship，无 FK）；
  - flashback_touches 追加只写：仅 `at`（建行时刻），无 updated_at。
  """

  use Ecto.Migration

  def change do
    create table(:flashback_event_archives, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:key, :text, null: false)
      add(:name, :text, null: false)
      add(:city, :text)
      add(:occurred_on, :date)
      add(:applied_count, :integer)
      add(:attended_count, :integer)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:flashback_event_archives, [:key],
        name: :flashback_event_archives_unique_key_index
      )
    )

    create table(:flashback_people, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :archive_event_id,
        references(:flashback_event_archives, type: :uuid, column: :id),
        null: false
      )

      add(:full_name, :text, null: false)
      add(:surname, :text)
      add(:city, :text)
      add(:occupation_then, :text)
      add(:gender, :text)
      # 敏感（KTD3）：明文触达通道，不进任何投影。
      add(:phone, :text)
      add(:email, :text)
      add(:role, :text, null: false, default: "learner")
      add(:participation, :text, null: false)
      add(:applied_at, :utc_datetime_usec)
      # 注册绑定（R27）；裸 uuid，不设 FK。
      add(:user_id, :uuid)
      # 实名公开档案页 slug（R32/R33，ADR-0014：发布即锁定）。
      add(:public_slug, :text)
      add(:public_slug_published_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:flashback_people, [:public_slug],
        name: :flashback_people_unique_public_slug_index
      )
    )

    # 找回匹配（R21：手机/邮箱精确匹配，可多档案命中）与场次名册查询。
    create(index(:flashback_people, [:archive_event_id]))
    create(index(:flashback_people, [:user_id]))
    create(index(:flashback_people, [:phone]))
    create(index(:flashback_people, [:email]))

    create table(:flashback_tokens, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:person_id, references(:flashback_people, type: :uuid, column: :id), null: false)

      # sha256 hex lower（KTD2：明文不落任何持久化载体）。
      add(:token_hash, :text, null: false)
      add(:claimed_by_user_id, :uuid)
      add(:claimed_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:replaced_by_id, :uuid)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:flashback_tokens, [:token_hash],
        name: :flashback_tokens_unique_token_hash_index
      )
    )

    create(index(:flashback_tokens, [:person_id]))

    create table(:flashback_answers, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:person_id, references(:flashback_people, type: :uuid, column: :id), null: false)

      add(:question_key, :text, null: false)
      # 当年原文（不可变，KTD4）。
      add(:raw_text, :text, null: false)
      # jsonb：[{start,len,reason?}]，grapheme 偏移。
      add(:fog_spans, {:array, :map}, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:flashback_answers, [:person_id, :question_key],
        name: :flashback_answers_unique_person_question_index
      )
    )

    create(index(:flashback_answers, [:person_id]))

    create table(:flashback_todays, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:person_id, references(:flashback_people, type: :uuid, column: :id), null: false)

      add(:now_status, :text)
      add(:want, :text)
      add(:need, :text)
      add(:say, :text)
      add(:want_give_tags, {:array, :text}, default: [])
      add(:mobilization, :map, default: %{})
      add(:newsletter_opt_in, :boolean, null: false, default: false)
      add(:reconnect_tags, {:array, :text}, default: [])
      add(:sent_to_wall_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:flashback_todays, [:person_id], name: :flashback_todays_unique_person_index)
    )

    create table(:flashback_quote_licenses, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:person_id, references(:flashback_people, type: :uuid, column: :id), null: false)

      add(:level, :text, null: false, default: "off")
      add(:question_key, :text)
      add(:chosen_quote_span, :map)
      add(:credited_note, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:flashback_quote_licenses, [:person_id],
        name: :flashback_quote_licenses_unique_person_index
      )
    )

    create table(:flashback_action_cards, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :proposer_person_id,
        references(:flashback_people, type: :uuid, column: :id)
      )

      add(:title, :text, null: false)
      add(:city, :text)
      add(:status, :text, null: false, default: "proposed")
      # 成场回填（U7）；现行 events 是租户资源，裸 uuid 引用。
      add(:event_id, :uuid)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:flashback_action_cards, [:status]))
    create(index(:flashback_action_cards, [:event_id]))
    create(index(:flashback_action_cards, [:proposer_person_id]))

    create table(:flashback_endorsements, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:card_id, references(:flashback_action_cards, type: :uuid, column: :id), null: false)
      add(:person_id, references(:flashback_people, type: :uuid, column: :id), null: false)
      add(:role_claimed, :text)

      add(:consented_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:flashback_endorsements, [:card_id, :person_id],
        name: :flashback_endorsements_unique_card_person_index
      )
    )

    create(index(:flashback_endorsements, [:person_id]))

    create table(:flashback_touches, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:person_id, references(:flashback_people, type: :uuid, column: :id), null: false)

      # 落地 token 可溯；裸 uuid。
      add(:token_id, :uuid)
      add(:event, :text, null: false)
      # 追加只写：建行时刻即事件时刻，无 updated_at。
      add(:at, :utc_datetime_usec, null: false, default: fragment("(now() AT TIME ZONE 'utc')"))
    end

    # 四率聚合（KTD10）：按人分事件计数 + 按 token 溯源。
    create(index(:flashback_touches, [:person_id, :event]))
    create(index(:flashback_touches, [:token_id]))

    create table(:flashback_outreaches, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:person_id, references(:flashback_people, type: :uuid, column: :id), null: false)

      add(:channel, :text, null: false)
      add(:template, :text, null: false)
      add(:batch, :text, null: false)
      add(:status, :text, null: false, default: "queued")
      add(:sent_at, :utc_datetime_usec)
      add(:unsubscribed_at, :utc_datetime_usec)
      add(:detail, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:flashback_outreaches, [:person_id, :channel, :batch],
        name: :flashback_outreaches_unique_send_index
      )
    )

    create(index(:flashback_outreaches, [:person_id]))
    create(index(:flashback_outreaches, [:batch]))
  end
end
