defmodule Cgc2046.Repo.Migrations.AddFlashbackOutreachLinks do
  @moduledoc """
  闪念间 #770：触达批次级微信 URL Link 缓存表。一个 batch 一条，未过期复用、
  过期重生成覆盖（unique index + upsert）；明文 token 不入库（KTD2，只以 cq
  拼在发送时的链接后）。
  """

  use Ecto.Migration

  def change do
    create table(:flashback_outreach_links, primary_key: false) do
      add(:id, :uuid,
        primary_key: true,
        null: false,
        default: fragment("gen_random_uuid()")
      )

      add(:batch, :text, null: false)
      add(:url_link, :text, null: false)
      add(:expires_at, :utc_datetime, null: false)

      add(:inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
      )
    end

    create unique_index(:flashback_outreach_links, [:batch],
             name: "flashback_outreach_links_unique_batch_index"
           )
  end
end
