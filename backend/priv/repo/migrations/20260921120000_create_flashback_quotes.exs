defmodule Cgc2046.Repo.Migrations.CreateFlashbackQuotes do
  use Ecto.Migration

  # R37 单句身份：每个授权圈选段一行 QUOTE（稳定 UUID，编辑圈选原地生效）。
  #   - span 引用宿主文本（answer 行或 today.* 字段），不复制文本；
  #   - answer_id 可空：today.* 宿主的 span 无 answer 行可指（渲染时按
  #     question_key 回落 flashback_todays 字段）；
  #   - 点赞 re-key：旧行按「该 person 第一段 span 对应的 quote」回填
  #     （与现行公开墙只展示首句的口径一致），随后 person_id 列删除——
  #     不保留兼容路径（AGENTS.md：不做向后兼容层）。
  #
  # 活表纪律豁免（backend/AGENTS.md）：flashback_likes 是生产增长表，但当前
  # 量级为试点期（行数 << 万级），唯一索引 + NOT NULL 改列的锁窗口在毫秒级，
  # 不走 concurrently / NOT VALID 两段式；行数增长到需要分段时另行处理。
  def up do
    create table(:flashback_quotes, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :quote_license_id,
        references(:flashback_quote_licenses, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      # today.* 宿主的 span 无 answer 行（宿主是 flashback_todays 字段）→ 可空。
      add(
        :answer_id,
        references(:flashback_answers, type: :uuid, column: :id, on_delete: :delete_all)
      )

      add(:question_key, :text, null: false)
      # 圈选区间（grapheme 偏移，结构同 fog span）：%{"start" => int, "len" => int}
      add(:span, :map, null: false)

      # 城市/年份快照（生成时从 person/archive 取；渲染不查档案，授权变更时
      # 由 sync 以 person 现值刷新）
      add(:city, :text)
      add(:year, :integer)
      # 单句撤回（可逆）；license 级联隐藏由服务层同步置位
      add(:hidden_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:flashback_quotes, [:quote_license_id]))
    create(index(:flashback_quotes, [:answer_id]))

    # ── 数据迁移：license 的每段 span → 一行 Quote ─────────────────────
    execute """
    INSERT INTO flashback_quotes
      (id, quote_license_id, answer_id, question_key, span, city, year, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      q.id,
      a.id,
      span_el->>'question_key',
      jsonb_build_object('start', (span_el->>'start')::int, 'len', (span_el->>'len')::int),
      COALESCE(p.city, arch.city),
      EXTRACT(YEAR FROM arch.occurred_on)::int,
      NOW(),
      NOW()
    FROM flashback_quote_licenses q
    JOIN flashback_people p ON p.id = q.person_id
    LEFT JOIN flashback_event_archives arch ON arch.id = p.archive_event_id
    CROSS JOIN LATERAL unnest(q.chosen_quote_spans) AS span_el
    LEFT JOIN flashback_answers a
      ON a.person_id = q.person_id AND a.question_key = span_el->>'question_key'
    WHERE q.chosen_quote_spans IS NOT NULL AND array_length(q.chosen_quote_spans, 1) > 0
    """

    # ── 点赞 re-key：quote_id 回填（旧行归到该 person 的第一句）─────────
    alter table(:flashback_likes) do
      add(
        :quote_id,
        references(:flashback_quotes, type: :uuid, column: :id, on_delete: :delete_all)
      )
    end

    # 「第一句」= spans[1] 坐标对应的 quote 行（全部行同事务同刻插入，
    # inserted_at 无法表达圈选顺序——必须按 (chosen_quote_spans)[1] 的
    # question_key + start + len 匹配，与现行公开墙只展示首句的口径一致）。
    execute """
    UPDATE flashback_likes l
    SET quote_id = first_quote.id
    FROM (
      SELECT q.id, ql.person_id
      FROM flashback_quote_licenses ql
      JOIN flashback_quotes q
        ON q.quote_license_id = ql.id
       AND q.question_key = (ql.chosen_quote_spans)[1]->>'question_key'
       AND (q.span->>'start')::int = ((ql.chosen_quote_spans)[1]->>'start')::int
       AND (q.span->>'len')::int = ((ql.chosen_quote_spans)[1]->>'len')::int
      WHERE ql.chosen_quote_spans IS NOT NULL AND array_length(ql.chosen_quote_spans, 1) > 0
    ) first_quote
    WHERE first_quote.person_id = l.person_id
    """

    # 防御：理论上每行 like 的 person 都有 license 才有赞；若无 quote 可回填
    # （license 被删但 like 残留等异常态），这些行无法表达「赞的是哪句」→ 删除。
    execute "DELETE FROM flashback_likes WHERE quote_id IS NULL"

    alter table(:flashback_likes) do
      modify(:quote_id, :uuid, null: false)
    end

    create(
      unique_index(:flashback_likes, [:quote_id, :voter_key],
        name: :flashback_likes_unique_quote_voter_index
      )
    )

    drop(
      unique_index(:flashback_likes, [:person_id, :voter_key],
        name: :flashback_likes_unique_person_voter_index
      )
    )

    alter table(:flashback_likes) do
      remove(:person_id)
    end
  end

  def down do
    alter table(:flashback_likes) do
      add(:person_id, references(:flashback_people, type: :uuid, column: :id))
    end

    execute """
    UPDATE flashback_likes l
    SET person_id = ql.person_id
    FROM flashback_quotes q
    JOIN flashback_quote_licenses ql ON ql.id = q.quote_license_id
    WHERE q.id = l.quote_id
    """

    alter table(:flashback_likes) do
      modify(:person_id, :uuid, null: false)
    end

    create(
      unique_index(:flashback_likes, [:person_id, :voter_key],
        name: :flashback_likes_unique_person_voter_index
      )
    )

    drop(
      unique_index(:flashback_likes, [:quote_id, :voter_key],
        name: :flashback_likes_unique_quote_voter_index
      )
    )

    alter table(:flashback_likes) do
      remove(:quote_id)
    end

    drop(table(:flashback_quotes))
  end
end
