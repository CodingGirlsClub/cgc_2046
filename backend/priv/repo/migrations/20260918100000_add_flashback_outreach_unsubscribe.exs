defmodule Cgc2046.Repo.Migrations.AddFlashbackOutreachUnsubscribe do
  @moduledoc """
  闪念间 U8/KTD6：退订按**人**抑制双通道——抑制真源落 flashback_people
  （outreach_unsubscribed_at），不再依赖 flashback_outreaches 行内标记（首封
  邮件点击退订时尚无发送行，行内标记会漏置位）。flashback_outreaches 是 U1
  新建未投产表，unsubscribed_at 列直接 drop（不留废弃路径）。
  """

  use Ecto.Migration

  def change do
    alter table(:flashback_people) do
      add(:outreach_unsubscribed_at, :utc_datetime_usec)
    end

    alter table(:flashback_outreaches) do
      remove(:unsubscribed_at)
    end
  end
end
