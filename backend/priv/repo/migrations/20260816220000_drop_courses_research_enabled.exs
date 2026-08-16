defmodule Cgc2046.Repo.Migrations.DropCoursesResearchEnabled do
  @moduledoc """
  课程 issue 学习闭环 U6(切片 H, #180;R14/Q12):删 `courses.research_enabled`。

  issue 卡是课程内容本体,恒走教研实例化——开关在 Course 上是死路径。
  Event 侧 `events.research_enabled` 保留(event-only 退出通道,语义:
  「这场活动不使用教研链路」)。migration 与消费方收紧同单元原子落地
  (plan Rsk1:dev 阶段无生产部署,删列不可逆可接受)。
  """

  use Ecto.Migration

  def up do
    alter table(:courses) do
      remove :research_enabled
    end
  end

  def down do
    alter table(:courses) do
      add :research_enabled, :boolean, null: false, default: true
    end
  end
end
