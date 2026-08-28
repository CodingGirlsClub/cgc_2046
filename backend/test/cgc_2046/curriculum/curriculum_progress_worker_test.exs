defmodule Cgc2046.Curriculum.CurriculumProgressWorkerTest do
  @moduledoc """
  CurriculumProgressWorker 测试(切片 H U5, #180):

  - 内容存在 + run waiting/running → succeeded
  - run 已终态不动;无内容不动
  - seeds 幂等:跑两遍不重复;两定义 published 且含单 manual step
  """
  use Cgc2046.DataCase, async: true

  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Curriculum.CurriculumProgressWorker
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  require Ash.Query

  defp content_fixture do
    %{
      "goals" => ["能写程序"],
      "issues" => [
        %{
          "id" => "py-first",
          "kind" => "handwork",
          "title" => "第一个程序",
          "story" => %{
            "as_a" => "学员",
            "given" => [],
            "goal" => "写问候程序",
            "materials" => [],
            "checklist" => [%{"id" => "c1", "text" => "能运行"}]
          }
        }
      ]
    }
  end

  defp create_curriculum_definition(workspace, actor) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "教研 #{Ecto.UUID.generate()}",
          type: :curriculum,
          input_schema: %{},
          node_def: %{"steps" => [%{"id" => "produce_issue_deck", "type" => "manual"}]}
        },
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    {:ok, published} =
      defn
      |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    published
  end

  # 教研 run:create → start(manual step 下 start_run 会 waiting;此处直接
  # 构造 running 态已足够——worker 只看非终态 + 内容存在)
  defp create_active_run(workspace, definition, course, status) do
    WorkflowRun
    |> Ash.Changeset.for_create(
      :create,
      %{
        definition_id: definition.id,
        definition_version: definition.version,
        input_snapshot: %{"key" => "course_#{course.id}", "course_id" => course.id}
      },
      tenant: workspace.id,
      authorize?: false
    )
    |> Ash.create!(tenant: workspace.id, authorize?: false)
    |> Ash.Changeset.for_update(:start, %{}, tenant: workspace.id, authorize?: false)
    |> Ash.update!(tenant: workspace.id, authorize?: false)
    |> case do
      run when status == :running -> run
      run -> put_status(workspace, run, status)
    end
  end

  defp put_status(workspace, run, :waiting) do
    run
    |> Ash.Changeset.for_update(:wait, %{}, tenant: workspace.id, authorize?: false)
    |> Ash.update!(tenant: workspace.id, authorize?: false)
  end

  defp put_status(workspace, run, :succeeded) do
    run
    |> Ash.Changeset.for_update(:complete, %{}, tenant: workspace.id, authorize?: false)
    |> Ash.update!(tenant: workspace.id, authorize?: false)
  end

  defp save_content(workspace, actor, course) do
    Cgc2046.Curriculum.Output
    |> Ash.Changeset.for_create(
      :upsert_content,
      %{
        key: Cgc2046.Curriculum.Output.course_key(course.id),
        kind: :issues,
        data: content_fixture(),
        submitted_by: actor.id
      },
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp fetch_run(run_id, workspace_id) do
    Ash.get!(WorkflowRun, run_id, tenant: workspace_id, authorize?: false)
  end

  test "内容存在 + run waiting/running → succeeded;无内容不动" do
    admin = Fixtures.platform_admin("rpw-u5")
    workspace = Fixtures.create_workspace(admin)
    definition = create_curriculum_definition(workspace, admin)

    course_a = EventFixtures.create_course(workspace, admin, %{title: "有内容课"})
    course_b = EventFixtures.create_course(workspace, admin, %{title: "无内容课"})

    run_running = create_active_run(workspace, definition, course_a, :running)
    run_waiting = create_active_run(workspace, definition, course_a, :waiting)
    run_no_content = create_active_run(workspace, definition, course_b, :running)

    save_content(workspace, admin, course_a)

    assert :ok = perform_job(CurriculumProgressWorker, %{})

    assert fetch_run(run_running.id, workspace.id).status == :succeeded
    assert fetch_run(run_waiting.id, workspace.id).status == :succeeded
    assert fetch_run(run_no_content.id, workspace.id).status == :running
  end

  test "run 已终态不动(succeeded 不重复处理)" do
    admin = Fixtures.platform_admin("rpw-u5-terminal")
    workspace = Fixtures.create_workspace(admin)
    definition = create_curriculum_definition(workspace, admin)
    course = EventFixtures.create_course(workspace, admin, %{})

    run = create_active_run(workspace, definition, course, :succeeded)
    save_content(workspace, admin, course)

    assert :ok = perform_job(CurriculumProgressWorker, %{})

    reloaded = fetch_run(run.id, workspace.id)
    assert reloaded.status == :succeeded
  end

  describe "seeds 幂等" do
    @tag :tmp_dir
    test "seeds 跑两遍:两定义 published、单 manual step、不重复" do
      workspace =
        Cgc2046.Accounts.Workspace
        |> Ash.Changeset.for_create(
          :create,
          %{slug: "2046", name: "默认社区", join_policy: :request},
          authorize?: false
        )
        |> Ash.create(authorize?: false)
        |> case do
          {:ok, ws} ->
            ws

          {:error, _} ->
            # 沙箱内已有同 slug(workspace 全局唯一)——复用
            Cgc2046.Accounts.Workspace
            |> Ash.Query.for_read(:get_by_slug, %{slug: "2046"})
            |> Ash.read_one!(authorize?: false)
        end

      run_seeds = fn ->
        seeds_path = Path.expand("../../../priv/repo/seeds.exs", __DIR__)
        Code.eval_file(seeds_path)
      end

      run_seeds.()
      run_seeds.()

      for {type, name} <- [{:curriculum, "教研 workflow"}, {:learning, "学习 workflow"}] do
        definitions =
          WorkflowDefinition
          |> Ash.Query.filter(name == ^name and type == ^type and status == :published)
          |> Ash.read!(authorize?: false, tenant: workspace.id)

        assert length(definitions) == 1, "#{name} 应恰好一条 published 定义"
        defn = hd(definitions)
        assert [%{"id" => step_id, "type" => "manual"}] = defn.node_def["steps"]
        assert is_binary(step_id)
      end
    end
  end
end
