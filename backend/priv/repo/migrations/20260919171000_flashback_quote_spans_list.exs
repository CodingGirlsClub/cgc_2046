defmodule Cgc2046.Repo.Migrations.FlashbackQuoteSpansList do
  use Ecto.Migration

  def up do
    alter table(:flashback_quote_licenses) do
      add :chosen_quote_spans, {:array, :map}
    end

    # 存量单句授权搬进数组(首句 = 原句,消费面取句顺序不变)
    execute """
    UPDATE flashback_quote_licenses
    SET chosen_quote_spans = CASE
      WHEN chosen_quote_span IS NOT NULL THEN
        ARRAY[jsonb_build_object(
          'question_key', question_key,
          'start', chosen_quote_span->'start',
          'len', chosen_quote_span->'len'
        )]::jsonb[]
      ELSE NULL
    END
    """

    alter table(:flashback_quote_licenses) do
      remove :question_key
      remove :chosen_quote_span
    end
  end

  def down do
    alter table(:flashback_quote_licenses) do
      add :question_key, :string
      add :chosen_quote_span, :map
    end

    execute """
    UPDATE flashback_quote_licenses
    SET question_key = chosen_quote_spans[1]->>'question_key',
        chosen_quote_span = jsonb_build_object(
          'start', chosen_quote_spans[1]->'start',
          'len', chosen_quote_spans[1]->'len'
        )
    WHERE chosen_quote_spans IS NOT NULL AND array_length(chosen_quote_spans, 1) > 0
    """

    alter table(:flashback_quote_licenses) do
      remove :chosen_quote_spans
    end
  end
end
