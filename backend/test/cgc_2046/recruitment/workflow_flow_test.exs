defmodule Cgc2046.Recruitment.WorkflowFlowTest do
  @moduledoc """
  U3 验收：申请状态机 × Workflow 引擎全链（R12/R8；Covers AE3, AE8, AE11, F2）。

  申请行是状态权威，WorkflowRun 是执行镜像（KTD1）：四个人工门控
  （submitted/interview/training/assigned），申请 create 同事务 start run，
  段位推进经资源 action 的 after_transaction 对 run `resume_signal`，拒绝/取消
  走 run `fail`/`cancel`。

  状态一致性映射表（本文件逐段断言）：

  | 申请 status | run status              |
  |-------------|-------------------------|
  | submitted   | waiting（submitted 门控）|
  | interview   | waiting（interview 门控）|
  | training    | waiting（training 门控） |
  | assigned    | succeeded               |
  | rejected    | failed                  |
  | canceled    | cancelled               |

  覆盖：F2 主干（submitted→interview→training→assigned）、rejected 必带原因
  （AE3 前半）、canceled 无必填原因（AE8）、初审豁免（AE11）、create 失败不落
  孤儿 run（事务回滚）、重复流转不二次推进、批次关闭不放行新申请但在途可走完、
  段位流转权限边界。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.EventsFixtures, as: EventFixtures

  alias Cgc2046.Recruitment.{
    ApplicationWorkflowInstantiator,
    RecruitmentCohort,
    VolunteerApplication
  }

  alias Cgc2046.Workflows.{SignalPublishWorker, WorkflowDefinition, WorkflowRun}

  @submitted_signal "volunteer_application.submitted"
  @interview_signal "volunteer_application.interview"
  @training_signal "volunteer_application.training"
  @assigned_signal "volunteer_application.assigned"
  @rejected_signal "volunteer_application.rejected"
  @canceled_signal "volunteer_application.canceled"

  setup do
    creator = Fixtures.platform_admin("flow-creator")
    workspace = Fixtures.create_workspace(creator)

    owner = Fixtures.register_user("flow-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    # 申请人不是台成员（R15：项目分配时才邀请入台），申请人本人也不能流转段位
    applicant = Fixtures.register_user("flow-applicant")

    cohort = open_cohort(workspace, owner, "第 1 批")

    %{
      creator: creator,
      workspace: workspace,
      owner: owner,
      applicant: applicant,
      cohort: cohort
    }
  end

  describe "create 申请（同事务实例化 run）" do
    test "run 创建并 waiting（首门控）+ 申请 submitted + 定义 find_or_create", ctx do
      %{workspace: ws, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort)

      assert application.status == :submitted
      assert application.workspace_id == ws.id
      assert application.user_id == applicant.id

      # run 镜像：首门控（submitted）挂起
      run = run_for(application)
      assert run.status == :waiting
      assert run.workspace_id == ws.id
      assert run.input_snapshot["volunteer_application_id"] == application.id
      assert run.input_snapshot["cohort_id"] == cohort.id
      assert run.input_snapshot["user_id"] == applicant.id

      # 定义按 workspace find_or_create：type=recruitment_application、published、
      # 四个人工门控（manual-only，无需 StepHandlerRegistry）
      definition =
        Ash.get!(WorkflowDefinition, run.definition_id, tenant: ws.id, authorize?: false)

      assert definition.type == :recruitment_application
      assert definition.status == :published
      assert definition.workspace_id == ws.id

      assert Enum.map(definition.node_def["steps"], &{&1["id"], &1["type"]}) == [
               {"submitted", "manual"},
               {"interview", "manual"},
               {"training", "manual"},
               {"assigned", "manual"}
             ]

      # 提交确认信号（R14 第 1 行：网申提交 → 提交确认）
      assert signal_types() == [@submitted_signal]
    end

    test "同台第二个申请复用既有定义（find_or_create 幂等），各自独立 run", ctx do
      %{workspace: ws, applicant: applicant, owner: owner, cohort: cohort} = ctx

      peer = Fixtures.register_user("flow-peer")

      assert {:ok, first} = apply_for(ws, applicant, cohort)
      assert {:ok, second} = apply_for(ws, peer, cohort)

      first_run = run_for(first)
      second_run = run_for(second)

      assert first_run.definition_id == second_run.definition_id
      assert first_run.id != second_run.id
      assert second_run.status == :waiting

      # 定义只有一份
      assert [%{id: definition_id}] =
               WorkflowDefinition
               |> Ash.Query.filter(type == :recruitment_application)
               |> Ash.read!(tenant: ws.id, authorize?: false)

      assert definition_id == first_run.definition_id

      # 两批共用定义也各自独立实例化
      close_cohort(cohort, ws, owner)
      next_cohort = open_cohort(ws, owner, "第 2 批")

      assert {:ok, third} = apply_for(ws, owner, next_cohort)
      assert run_for(third).definition_id == definition_id
    end

    test "create 失败（同批重复申请）→ 事务回滚不留孤儿 run", ctx do
      %{workspace: ws, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, first} = apply_for(ws, applicant, cohort)
      runs_before = runs_in(ws)

      assert {:error, error} = apply_for(ws, applicant, cohort, %{position: :tutor})
      assert_business_code(error, "volunteer_application_already_submitted")

      # 失败事务里的 run 不落库：run 集合与失败前逐 id 一致
      runs_after = runs_in(ws)
      assert Enum.map(runs_after, & &1.id) == Enum.map(runs_before, & &1.id)
      assert [%{id: run_id}] = runs_after
      assert run_id == run_for(first).id

      # 无孤儿 run：每个 run 都能回溯到真实申请行
      for run <- runs_after do
        assert Ash.get!(
                 VolunteerApplication,
                 run.input_snapshot["volunteer_application_id"],
                 tenant: ws.id,
                 authorize?: false
               )
      end
    end
  end

  describe "F2 主干（submitted → interview → training → assigned）" do
    test "逐段流转：状态与 run 镜像一致，assigned 时 run succeeded", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort, creator: creator} = ctx

      event = EventFixtures.create_event(ws, creator)

      assert {:ok, application} = apply_for(ws, applicant, cohort)
      assert_run_status(application, :waiting)

      # 初审通过 → interview 段（run 放行 submitted 门控，仍挂起在 interview 门控）
      assert {:ok, application} = advance(ws, owner, application, :advance_to_interview)
      assert application.status == :interview
      assert_run_status(application, :waiting)

      # 群面通过 → training 段
      assert {:ok, application} = advance(ws, owner, application, :advance_to_training)
      assert application.status == :training
      assert_run_mirror(application, :waiting)

      # 训练营完成·项目分配 → assigned，run 终态 succeeded
      assert {:ok, assigned} =
               advance(ws, owner, application, :assign, %{
                 assigned_event_id: event.id,
                 assignment_note: "教程研究员：教程 3 章"
               })

      assert assigned.status == :assigned
      assert assigned.assigned_event_id == event.id
      assert assigned.assignment_note == "教程研究员：教程 3 章"
      refute is_nil(assigned.assigned_at)

      run = assert_run_status(assigned, :succeeded)
      refute is_nil(run.finished_at)

      # 每段一个段位信号（R14 阶段通知表的数据面）
      assert signal_types() ==
               Enum.sort([
                 @submitted_signal,
                 @interview_signal,
                 @training_signal,
                 @assigned_signal
               ])

      # 信号携带业务键与幂等键（U4 订阅方消费）
      job = signal_job(@assigned_signal)
      assert job.args["data"]["volunteer_application_id"] == assigned.id
      assert job.args["data"]["status"] == "assigned"
      assert job.args["data"]["idempotency_key"] == @assigned_signal <> ":" <> assigned.id
      assert job.args["data"]["workspace_id"] == ws.id
    end

    test "重复流转同一段位被拒（源状态守卫），run 不二次推进", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort)
      assert {:ok, application} = advance(ws, owner, application, :advance_to_interview)

      run = run_for(application)

      # 同段位再来一次：源状态不符（不是 submitted）→ 稳定 code，状态与 run 均不变
      assert {:error, error} = advance(ws, owner, application, :advance_to_interview)
      assert_business_code(error, "volunteer_application_invalid_transition")

      assert reload(application).status == :interview
      stale_run = run_for(application)
      assert stale_run.status == :waiting
      assert stale_run.version == run.version

      # 越段流转同样被拒（training 段才能 assign）
      assert {:error, error} = advance(ws, owner, application, :assign, %{})
      assert_business_code(error, "volunteer_application_invalid_transition")
    end

    test "run 不可回溯时段位流转仍成功（申请行是 checkpoint，镜像 best-effort）", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort)
      run = run_for(application)

      # 布置：抹掉 run 的实例键（模拟 run 不可回溯）——业务状态不受影响
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Repo,
          "UPDATE workflow_runs SET input_snapshot = input_snapshot - 'key' WHERE id = $1",
          [Ecto.UUID.dump!(run.id)]
        )

      assert {:ok, advanced} = advance(ws, owner, application, :advance_to_interview)
      assert advanced.status == :interview

      # 拒绝路径同样不阻塞（run 镜像 best-effort，申请行才是 checkpoint）
      assert {:ok, rejected} = advance(ws, owner, advanced, :reject, %{reason: "群面未通过"})
      assert rejected.status == :rejected
    end

    test "run 非 waiting 时直接 resume_signal 不推进（引擎状态守卫）", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort)
      assert {:ok, application} = advance(ws, owner, application, :advance_to_interview)
      assert {:ok, application} = advance(ws, owner, application, :advance_to_training)
      assert {:ok, assigned} = advance(ws, owner, application, :assign, %{})

      succeeded_run = run_for(assigned)
      assert succeeded_run.status == :succeeded

      assert {:error, %Ash.Error.Invalid{}} =
               succeeded_run
               |> Ash.Changeset.for_update(
                 :resume_signal,
                 %{"signal_type" => "workflow.training", "payload" => %{}},
                 actor: owner,
                 tenant: ws.id,
                 authorize?: false
               )
               |> Ash.update(tenant: ws.id, authorize?: false)

      assert run_for(assigned).status == :succeeded
    end
  end

  describe "rejected（AE3 前半）" do
    test "未填原因 → 保存被拒；填原因 → rejected + run failed + 信号含原因", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort)

      # 缺原因 / 全空白原因 → 拒（稳定 code），申请与 run 都不动
      for missing <- [%{}, %{reason: nil}, %{reason: "   "}] do
        assert {:error, error} = advance(ws, owner, application, :reject, missing)
        assert_business_code(error, "volunteer_application_rejection_reason_required")
      end

      assert reload(application).status == :submitted
      assert run_for(application).status == :waiting

      assert {:ok, rejected} = advance(ws, owner, application, :reject, %{reason: "名额已满"})

      assert rejected.status == :rejected
      assert rejected.rejection_reason == "名额已满"
      assert_run_status(rejected, :failed)

      job = signal_job(@rejected_signal)
      assert job.args["data"]["rejection_reason"] == "名额已满"
      assert job.args["data"]["volunteer_application_id"] == rejected.id
    end

    test "interview / training 段同样可拒绝并终止 run", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      peer = Fixtures.register_user("flow-reject-peer")

      assert {:ok, at_interview} = apply_for(ws, applicant, cohort)
      assert {:ok, at_interview} = advance(ws, owner, at_interview, :advance_to_interview)

      assert {:ok, rejected} = advance(ws, owner, at_interview, :reject, %{reason: "群面未通过"})
      assert rejected.status == :rejected
      assert_run_status(rejected, :failed)

      assert {:ok, at_training} = apply_for(ws, peer, cohort)
      assert {:ok, at_training} = advance(ws, owner, at_training, :advance_to_interview)
      assert {:ok, at_training} = advance(ws, owner, at_training, :advance_to_training)

      assert {:ok, rejected2} = advance(ws, owner, at_training, :reject, %{reason: "训练营缺席"})
      assert rejected2.status == :rejected
      assert_run_status(rejected2, :failed)

      # assigned 是终态：不可再拒绝
      assert {:ok, third} = apply_for(ws, Fixtures.register_user("flow-reject-third"), cohort)
      {:ok, assigned} = assign_through(ws, owner, third)
      assert {:error, error} = advance(ws, owner, assigned, :reject, %{reason: "反悔"})
      assert_business_code(error, "volunteer_application_invalid_transition")
    end
  end

  describe "canceled（AE8）" do
    test "无原因即可取消 → canceled + run cancelled；备注选填有则记录", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort)
      assert {:ok, canceled} = advance(ws, owner, application, :cancel, %{})

      assert canceled.status == :canceled
      assert is_nil(canceled.rejection_reason)
      assert_run_status(canceled, :cancelled)

      job = signal_job(@canceled_signal)
      assert job.args["data"]["volunteer_application_id"] == canceled.id
      assert job.args["data"]["status"] == "canceled"

      # 备注选填（ER：rejected 必填原因；canceled 备注选填，同列承载）
      peer = Fixtures.register_user("flow-cancel-peer")
      assert {:ok, second} = apply_for(ws, peer, cohort)
      assert {:ok, second} = advance(ws, owner, second, :advance_to_interview)

      assert {:ok, noted} = advance(ws, owner, second, :cancel, %{reason: "本人主动放弃"})
      assert noted.status == :canceled
      assert noted.rejection_reason == "本人主动放弃"
      assert_run_status(noted, :cancelled)
    end

    test "assigned 终态不可取消（R12 状态图）", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort)
      assert {:ok, assigned} = assign_through(ws, owner, application)

      assert {:error, error} = advance(ws, owner, assigned, :cancel, %{})
      assert_business_code(error, "volunteer_application_invalid_transition")
      assert_run_status(assigned, :succeeded)
    end
  end

  describe "约束执行（R8）" do
    test "已 assigned 者下一批申请：初审豁免直入 interview 段，不发初审结果通知（AE11）", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, first} = apply_for(ws, applicant, cohort)
      assert {:ok, first} = assign_through(ws, owner, first)
      assert_run_status(first, :succeeded)

      # 下一批：关闭旧批 → 开新批（唯一 open 约束）
      close_cohort(cohort, ws, owner)
      next_cohort = open_cohort(ws, owner, "第 2 批")

      assert {:ok, exempted} = apply_for(ws, applicant, next_cohort, %{position: :tutor})

      # 初审豁免：状态直入 interview，run 首段门控已放行（仍 waiting 在 interview 门控）
      assert exempted.status == :interview
      run = run_for(exempted)
      assert run.status == :waiting

      # 豁免事实落 run facts（来源申请可回溯）
      assert %{"exempted" => true, "reason" => "previous_assigned_application"} =
               run.facts["initial_review"]

      assert run.facts["initial_review"]["source_application_id"] == first.id

      # 不发初审结果通知：该申请只入队提交确认，无 interview 段信号（初审结果通知
      # 由「初次进入 interview 段」的业务信号承载；上一份申请的 interview 信号不串味）
      assert signal_types_for(exempted.id) == [@submitted_signal]
      refute @interview_signal in signal_types_for(exempted.id)

      # 新职位训练营段必修：interview → training → assigned 逐段仍走
      assert {:ok, at_training} = advance(ws, owner, exempted, :advance_to_training)
      assert at_training.status == :training

      assert {:ok, at_assigned} = advance(ws, owner, at_training, :assign, %{})
      assert at_assigned.status == :assigned
      assert_run_status(at_assigned, :succeeded)
    end

    test "批次关闭不放行新申请，在途申请照常走完", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, in_flight} = apply_for(ws, applicant, cohort)

      close_cohort(cohort, ws, owner)
      newcomer = Fixtures.register_user("flow-closed-newcomer")

      assert {:error, error} = apply_for(ws, newcomer, cohort)
      assert_business_code(error, "volunteer_application_cohort_closed")

      # 在途申请不受影响：段位可继续推进到终态
      assert {:ok, in_flight} = assign_through(ws, owner, in_flight)
      assert in_flight.status == :assigned
      assert_run_status(in_flight, :succeeded)
    end
  end

  describe "段位流转权限（KTD2）" do
    test "非 Owner/Admin（含申请人本人）不能流转；platform_admin 可穿透", ctx do
      %{workspace: ws, owner: owner, creator: creator, applicant: applicant, cohort: cohort} = ctx

      member = Fixtures.register_user("flow-member")
      Fixtures.add_member(ws, member, [:volunteer])

      assert {:ok, application} = apply_for(ws, applicant, cohort)

      assert {:error, %Ash.Error.Forbidden{}} =
               advance(ws, member, application, :advance_to_interview)

      assert {:error, %Ash.Error.Forbidden{}} =
               advance(ws, applicant, application, :advance_to_interview)

      assert {:error, %Ash.Error.Forbidden{}} =
               advance(ws, member, application, :reject, %{reason: "越权"})

      assert {:error, %Ash.Error.Forbidden{}} = advance(ws, member, application, :cancel, %{})

      # run 未被越权方推进
      assert run_for(application).status == :waiting

      # Owner 与 platform_admin（穿透）均可流转
      assert {:ok, _} = advance(ws, owner, application, :advance_to_interview)
      assert {:ok, _} = advance(ws, creator, application, :advance_to_training)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp apply_for(workspace, actor, cohort, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          cohort_id: cohort.id,
          position: :event_moderator,
          city: "上海",
          heard_about_us: "公众号",
          has_internal_referrer: false,
          message: "希望参与"
        },
        attrs
      )

    VolunteerApplication
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  defp advance(workspace, actor, application, action, args \\ %{}) do
    application
    |> Ash.Changeset.for_update(action, args, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp assign_through(workspace, actor, application) do
    with {:ok, application} <- advance(workspace, actor, application, :advance_to_interview),
         {:ok, application} <- advance(workspace, actor, application, :advance_to_training),
         {:ok, assigned} <- advance(workspace, actor, application, :assign, %{}) do
      {:ok, assigned}
    end
  end

  # 申请 → run（无 workflow_run_id 列：经实例键回溯，U3 起 run 的实例键单源在
  # ApplicationWorkflowInstantiator.run_key/1）
  defp run_for(application) do
    key = ApplicationWorkflowInstantiator.run_key(application.id)

    WorkflowRun
    |> Ash.Query.filter(input_snapshot["key"] == ^key)
    |> Ash.read_one!(tenant: application.workspace_id, authorize?: false)
  end

  defp runs_in(workspace) do
    WorkflowRun |> Ash.read!(tenant: workspace.id, authorize?: false)
  end

  defp reload(application) do
    Ash.get!(VolunteerApplication, application.id,
      tenant: application.workspace_id,
      authorize?: false
    )
  end

  # 状态一致性映射表断言：申请 status ↔ run status（见 moduledoc）
  defp assert_run_status(application, expected) do
    run = run_for(application)
    assert run.status == expected, "run mirror mismatch: #{run.status} != #{expected}"

    run
  end

  defp assert_run_mirror(application, expected), do: assert_run_status(application, expected)

  defp assert_business_code(error, code) do
    assert %Ash.Error.Invalid{errors: errors} = error

    assert Enum.any?(errors, &match?(%BusinessError{code: ^code}, &1)),
           "expected #{code}, got: #{inspect(errors)}"
  end

  # 只取本域信号（Oban 队列里有其他域的作业，测试进程可见——按前缀收敛，
  # 断言本域信号集合时不受噪声干扰）
  defp signal_types do
    all_enqueued(worker: SignalPublishWorker)
    |> Enum.map(& &1.args["signal_type"])
    |> Enum.filter(&String.starts_with?(&1, "volunteer_application."))
    |> Enum.sort()
  end

  # 某一份申请入队的信号类型（豁免路径要按申请隔离断言）
  defp signal_types_for(application_id) do
    all_enqueued(worker: SignalPublishWorker)
    |> Enum.filter(&(&1.args["data"]["volunteer_application_id"] == application_id))
    |> Enum.map(& &1.args["signal_type"])
    |> Enum.sort()
  end

  defp signal_job(signal_type) do
    Enum.find(all_enqueued(worker: SignalPublishWorker), fn job ->
      job.args["signal_type"] == signal_type
    end) || flunk("no enqueued signal #{signal_type}")
  end

  defp create_cohort(workspace, actor, name) do
    {:ok, cohort} =
      RecruitmentCohort
      |> Ash.Changeset.for_create(
        :create,
        %{name: name, apply_deadline_at: DateTime.add(DateTime.utc_now(), 14, :day)},
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    cohort
  end

  defp open_cohort(workspace, actor, name) do
    cohort = create_cohort(workspace, actor, name)

    {:ok, opened} =
      cohort
      |> Ash.Changeset.for_update(:open, %{}, tenant: workspace.id, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    opened
  end

  defp close_cohort(cohort, workspace, actor) do
    {:ok, closed} =
      cohort
      |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    closed
  end
end
