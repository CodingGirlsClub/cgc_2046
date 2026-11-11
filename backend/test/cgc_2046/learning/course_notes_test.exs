defmodule Cgc2046.Learning.CourseNotesTest do
  @moduledoc """
  Course Notes 服务端行为（TDD 首切片）：
  - 创建：actor 归属、课程访问、服务端去重；
  - 读取：只返回本人；
  - 编辑/删除：仅本人；NOTE 硬删除后可重新加入；
  - source material 参与去重，不同 source 可各存一条。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Curriculum.CourseRevision
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Learning.{Attempt, CourseNotes, Runs}
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  setup do
    admin = Fixtures.platform_admin("notes")
    workspace = Fixtures.create_workspace(admin)
    course = EventFixtures.create_course(workspace, admin, %{title: "Notes Course"})

    learner = Fixtures.register_user("notes-learner")
    enrollment = enroll(course, learner)

    outsider = Fixtures.register_user("notes-outsider")
    Fixtures.add_member(workspace, outsider)

    %{
      admin: admin,
      workspace: workspace,
      course: course,
      learner: learner,
      enrollment: enrollment,
      outsider: outsider
    }
  end

  test "creates a note owned by the actor and dedupes normalized text", ctx do
    attrs = %{
      course_id: ctx.course.id,
      issue_id: "issue-1",
      source_material_id: "mat-1",
      text: "  第一条   笔记  "
    }

    assert {:ok, note} = CourseNotes.create(ctx.learner, attrs)
    assert note.user_id == ctx.learner.id
    assert note.workspace_id == ctx.workspace.id
    assert note.course_id == ctx.course.id
    assert note.issue_id == "issue-1"
    assert note.source_material_id == "mat-1"
    assert note.kind == :note
    assert note.text == "第一条   笔记"
    assert note.dedupe_hash

    assert {:ok, same} =
             CourseNotes.create(ctx.learner, %{
               course_id: ctx.course.id,
               issue_id: "issue-1",
               source_material_id: "mat-1",
               text: "第一条 笔记"
             })

    assert same.id == note.id

    assert {:ok, other_source} =
             CourseNotes.create(ctx.learner, %{
               course_id: ctx.course.id,
               issue_id: "issue-1",
               source_material_id: "mat-2",
               text: "第一条 笔记"
             })

    assert other_source.id != note.id
  end

  test "lists only the actor's notes and rejects creation without course access", ctx do
    assert {:ok, _note} =
             CourseNotes.create(ctx.learner, %{
               course_id: ctx.course.id,
               issue_id: "issue-1",
               text: "only mine"
             })

    assert {:ok, [listed]} = CourseNotes.list(ctx.learner, ctx.course.id)
    assert listed.text == "only mine"

    assert {:ok, []} = CourseNotes.list(ctx.outsider, ctx.course.id)

    assert {:error, :course_not_accessible} =
             CourseNotes.create(ctx.outsider, %{
               course_id: ctx.course.id,
               issue_id: "issue-1",
               text: "not allowed"
             })
  end

  test "updates/deletes only the owner's note and allows re-adding after hard delete",
       ctx do
    assert {:ok, note} =
             CourseNotes.create(ctx.learner, %{
               course_id: ctx.course.id,
               issue_id: "issue-1",
               source_material_id: "mat-1",
               text: "before"
             })

    assert {:ok, updated} = CourseNotes.update(ctx.learner, note.id, "after")
    assert updated.text == "after"

    assert {:error, :not_found} = CourseNotes.update(ctx.outsider, note.id, "hijack")
    assert {:error, :not_found} = CourseNotes.delete(ctx.outsider, note.id)

    assert {:ok, true} = CourseNotes.delete(ctx.learner, note.id)
    assert {:ok, []} = CourseNotes.list(ctx.learner, ctx.course.id)

    assert {:ok, re_added} =
             CourseNotes.create(ctx.learner, %{
               course_id: ctx.course.id,
               issue_id: "issue-1",
               source_material_id: "mat-1",
               text: "after"
             })

    assert re_added.id != note.id
  end

  test "hard-deletes user notes and tombstones retro notes", ctx do
    assert {:ok, note} =
             CourseNotes.create(ctx.learner, %{
               course_id: ctx.course.id,
               issue_id: "issue-1",
               text: "hard delete me"
             })

    assert {:ok, true} = CourseNotes.delete(ctx.learner, note.id)
    assert {:error, _} = Ash.get(Cgc2046.Learning.CourseNote, note.id, authorize?: false)

    attrs = %{
      workspace_id: ctx.workspace.id,
      user_id: ctx.learner.id,
      course_id: ctx.course.id,
      issue_id: "issue-1",
      kind: :retro,
      text: "【复盘】tombstone",
      retro_key: "retro:#{ctx.workspace.id}:#{ctx.course.id}:1:issue-1"
    }

    retro =
      Cgc2046.Learning.CourseNote
      |> Ash.Changeset.for_create(:create_note, attrs, actor: ctx.learner)
      |> Ash.create!()

    assert {:ok, true} = CourseNotes.delete(ctx.learner, retro.id)
    assert {:ok, []} = CourseNotes.list(ctx.learner, ctx.course.id)

    tombstone =
      Ash.get!(Cgc2046.Learning.CourseNote, retro.id, authorize?: false)

    assert tombstone.deleted_at
  end

  test "retro key is unique for idempotency", ctx do
    attrs = %{
      workspace_id: ctx.workspace.id,
      user_id: ctx.learner.id,
      course_id: ctx.course.id,
      issue_id: "issue-1",
      kind: :retro,
      text: "【复盘】第一次",
      retro_key: "retro:#{ctx.workspace.id}:#{ctx.course.id}:1:issue-1"
    }

    Cgc2046.Learning.CourseNote
    |> Ash.Changeset.for_create(:create_note, attrs, actor: ctx.learner)
    |> Ash.create!()

    assert {:error, _} =
             Cgc2046.Learning.CourseNote
             |> Ash.Changeset.for_create(:create_note, attrs, actor: ctx.learner)
             |> Ash.create()
  end

  test "creates one idempotent retro after required objectives are mastered", ctx do
    content = %{
      "goals" => [],
      "issues" => [
        %{
          "id" => "issue-1",
          "title" => "完成目标",
          "objectives" => [
            %{
              "id" => "obj-1",
              "title" => "掌握目标",
              "required" => true,
              "prereq_ids" => [],
              "rubric" => [%{"id" => "r1"}]
            }
          ]
        }
      ]
    }

    revision = publish_revision(ctx.workspace, ctx.course, content)
    run = create_completed_run(ctx, revision.id)
    assert run.id

    assert {:ok, retro} = CourseNotes.ensure_retro(ctx.learner, ctx.course.id, "issue-1")
    assert retro.kind == :retro
    assert retro.text =~ "【复盘】"
    assert retro.text =~ "掌握目标"

    assert {:ok, same} = CourseNotes.ensure_retro(ctx.learner, ctx.course.id, "issue-1")
    assert same.id == retro.id

    assert {:ok, true} = CourseNotes.delete(ctx.learner, retro.id)
    assert {:ok, nil} = CourseNotes.ensure_retro(ctx.learner, ctx.course.id, "issue-1")
  end

  test "does not create retro before required objectives are mastered", ctx do
    assert {:ok, nil} = CourseNotes.ensure_retro(ctx.learner, ctx.course.id, "issue-1")
  end

  test "rejects blank or oversized text", ctx do
    assert {:error, :invalid_text} =
             CourseNotes.create(ctx.learner, %{
               course_id: ctx.course.id,
               issue_id: "issue-1",
               text: "   "
             })

    assert {:error, :invalid_text} =
             CourseNotes.create(ctx.learner, %{
               course_id: ctx.course.id,
               issue_id: "issue-1",
               text: String.duplicate("x", 4001)
             })
  end

  defp publish_revision(workspace, course, content) do
    {:ok, revision} =
      CourseRevision
      |> Ash.Changeset.for_create(
        :create,
        %{
          course_id: course.id,
          number: 1,
          content: content,
          published_at: DateTime.utc_now()
        },
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, authorize?: false)

    course
    |> Ash.Changeset.for_update(
      :bind_current_revision,
      %{current_revision_id: revision.id},
      tenant: workspace.id
    )
    |> Ash.update!(tenant: workspace.id, authorize?: false)

    revision
  end

  defp create_completed_run(ctx, revision_id) do
    {:ok, definition} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Notes Retro workflow",
          type: :learning,
          input_schema: %{},
          node_def: %{"steps" => []}
        },
        tenant: ctx.workspace.id,
        actor: ctx.admin
      )
      |> Ash.create(tenant: ctx.workspace.id, actor: ctx.admin)

    {:ok, definition} =
      definition
      |> Ash.Changeset.for_update(:publish, %{}, actor: ctx.admin)
      |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

    run =
      WorkflowRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          definition_id: definition.id,
          definition_version: definition.version,
          input_snapshot: %{
            "key" => Runs.instance_key(ctx.enrollment.id, revision_id),
            "enrollment_id" => ctx.enrollment.id,
            "user_id" => ctx.learner.id,
            "course_id" => ctx.course.id,
            "course_revision_id" => revision_id
          }
        },
        tenant: ctx.workspace.id,
        authorize?: false
      )
      |> Ash.create!(tenant: ctx.workspace.id, authorize?: false)

    Attempt
    |> Ash.Changeset.for_create(
      :create,
      %{
        learning_run_id: run.id,
        course_revision_id: revision_id,
        objective_id: "obj-1",
        evidence: "已完成",
        rubric_results: [%{"criterion_id" => "r1", "met" => true}],
        passed: true,
        rationale: "rubric 全覆盖",
        confidence: 0.9
      },
      tenant: ctx.workspace.id,
      authorize?: false
    )
    |> Ash.create!(tenant: ctx.workspace.id, authorize?: false)

    run
  end

  defp enroll(course, learner) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        course_id: course.id,
        user_id: learner.id
      })
      |> Ash.create(tenant: course.workspace_id, actor: learner)

    enrollment
  end
end
