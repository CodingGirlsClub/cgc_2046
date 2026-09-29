defmodule Cgc2046.Repo.Migrations.AddFlashbackEmailBounceSuppression do
  @moduledoc """
  闪念间邮箱死信抑制（2026-09-28 唤醒战役复盘）：服务商硬退信判死后，抑制
  真源落 flashback_people（outreach_email_bounced_at）——消费面将其人的
  email 视为不存在：:email 派发跳过、:all 自动回落 sms 腿；人不被整体
  抑制（退订才是整人闸，suppressed_person_ids 只承载退订）。时间戳而非
  boolean：判死时刻可溯源，误杀清空即平反；与退订标记分列：退订是
  用户主动动作（R30），死信是运营侧观测事实，混列会污染退订统计。
  """

  use Ecto.Migration

  def change do
    alter table(:flashback_people) do
      add(:outreach_email_bounced_at, :utc_datetime_usec)
    end
  end
end
