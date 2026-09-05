defmodule Cgc2046.Repo.Migrations.AddPrepCourseIdsToInvitations do
  use Ecto.Migration

  # 邀请即完整意图：绑定课程,接受时自动 assign_prep_tutor(nil = 不绑定)
  def change do
    alter table(:invitations) do
      add :prep_course_ids, {:array, :uuid}
    end
  end
end
