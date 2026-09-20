defmodule Cgc2046.Repo.Migrations.FlashbackTodayFogSpans do
  @moduledoc """
  今天的你句级雾面——与当年答案同一套 FogSpans 坐标/校验，
  载体为 flashback_todays.fog_spans（map：field("now"/"want"/"need"/"say")
  → spans 列表）。nullable 无默认：未启用即空，旧客户端零感知。
  """

  use Ecto.Migration

  def change do
    alter table(:flashback_todays) do
      add(:fog_spans, :map)
    end
  end
end
