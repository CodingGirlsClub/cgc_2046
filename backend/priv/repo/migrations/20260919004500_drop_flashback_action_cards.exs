defmodule Cgc2046.Repo.Migrations.DropFlashbackActionCards do
  @moduledoc """
  行动卡机制整体移除（KD2：许愿卡取代，成场/角色/通知链不再存在）。
  down 不重建——回滚按 git 历史恢复代码，数据不恢复。
  """

  use Ecto.Migration

  def up do
    drop_if_exists(table(:flashback_endorsements))
    drop_if_exists(table(:flashback_action_cards))
  end

  def down do
    # 有意留空：行动卡实体已删，重建表无消费者（KD2）
  end
end
