defmodule Cgc2046.Repo.Migrations.AddFlashbackActionCardDoneMedia do
  @moduledoc """
  闪念间 U7/R13：done 态回贴——活动照片 data-URL（头像先例同款口径）与回顾
  文字。flashback_action_cards 是 U1 新建未投产表，直接加列。
  """

  use Ecto.Migration

  def change do
    alter table(:flashback_action_cards) do
      add(:photo_url, :text)
      add(:recap, :text)
    end
  end
end
