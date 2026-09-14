defmodule Cgc2046.Admission.AttendanceTest do
  @moduledoc """
  U5/KTD4 核销（R6、R11；AE4 前半）：Attendance 资源与 `check_in` action。

  四面：授权（主理人 / Owner·Admin / 平台管理员放行，无关者与报名本人拒绝）、
  码定位（错码 / 非 confirmed / 跨场 / event 不存在统一 `attendance_invalid_code`）、
  幂等（同一报名第二次核销 `attendance_already_checked_in`，不落第二行、不重复审计）、
  并发（两进程赛同一报名 → 恰一行，唯一索引承担幂等）。

  并发用例的沙箱纪律（`OrderEnrollmentLockTest` 同款）：自管 owner + `unboxed_run`
  真实提交——shared sandbox 下普通进程的事务只是 savepoint，行锁与唯一索引都不可见，
  竞态不成立（`enrollment_concurrency_test` 同因同解）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Accounts.User
  alias Cgc2046.Admission.{Attendance, Enrollment}
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.Moderators
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.MiniprogramFixtures.Barrier
  alias Cgc2046.RandomCode
  alias Cgc2046.Repo

  require Ash.Query

  describe "check_in/4 授权" do
    test "主理人核销 confirmed 报名：Attendance 一行（核销人/时间/方式）+ 审计一行" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      moderator = assign_moderator(event, workspace, owner, "attendance-moderator")
      enrollment = create_confirmed_enrollment(event)

      assert {:ok, attendance} = check_in(event, enrollment.check_in_code, :manual, moderator)

      assert attendance.enrollment_id == enrollment.id
      assert attendance.event_id == event.id
      assert attendance.workspace_id == workspace.id
      assert attendance.operator_id == moderator.id
      assert attendance.method == :manual
      assert %DateTime{} = attendance.checked_in_at

      # 落库口径（非仅内存态）
      reloaded = Ash.get!(Attendance, attendance.id, authorize?: false)
      assert reloaded.checked_in_at == attendance.checked_in_at
      assert attendance_count(enrollment.id) == 1

      assert [log] = audit_logs(enrollment.id)
      assert log.action == :attendance_check_in
      assert log.actor_id == moderator.id
      assert log.target_type == :enrollment
      assert log.target_id == enrollment.id
      assert log.metadata["event_id"] == event.id
      assert log.metadata["method"] == "manual"
    end

    test "scan / manual 两种方式都落库；workspace Owner 与 Admin（非主理人）放行" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)

      admin = Fixtures.register_user("attendance-ws-admin")
      Fixtures.add_member(workspace, admin, [:admin])

      owner_enrollment = create_confirmed_enrollment(event)
      admin_enrollment = create_confirmed_enrollment(event)

      assert {:ok, by_owner} = check_in(event, owner_enrollment.check_in_code, :scan, owner)
      assert by_owner.operator_id == owner.id
      assert by_owner.method == :scan

      assert {:ok, by_admin} = check_in(event, admin_enrollment.check_in_code, :manual, admin)
      assert by_admin.operator_id == admin.id
    end

    test "PlatformAdmin 非本 workspace 成员亦放行（治理兜底，与 waive_payment 同款）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      enrollment = create_confirmed_enrollment(event)
      platform_admin = Fixtures.platform_admin("attendance-platform-admin")

      assert {:ok, attendance} =
               check_in(event, enrollment.check_in_code, :manual, platform_admin)

      assert attendance.operator_id == platform_admin.id
    end

    test "无关用户与报名本人核销被拒，不落行" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      learner = Fixtures.register_user("attendance-self-checkin")
      {:ok, enrollment} = create_enrollment(event, learner)
      outsider = Fixtures.register_user("attendance-outsider")

      assert {:error, %Ash.Error.Forbidden{}} =
               check_in(event, enrollment.check_in_code, :manual, outsider)

      # 参与者本人不是主理人、也不是 workspace 管理角色（A3 与 A4 是两个主体）
      assert {:error, %Ash.Error.Forbidden{}} =
               check_in(event, enrollment.check_in_code, :manual, learner)

      assert attendance_count(enrollment.id) == 0
    end

    test "event_id 与 tenant 不一致被拒（policy 按 tenant 直读 Event，读不到即拒）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      enrollment = create_confirmed_enrollment(event)
      moderator = assign_moderator(event, workspace, owner, "attendance-tenant-moderator")

      other_workspace = Fixtures.create_workspace(Fixtures.platform_admin("attendance-other-ws"))

      assert {:error, %Ash.Error.Forbidden{}} =
               Attendance
               |> Ash.Changeset.for_create(:check_in, %{
                 event_id: event.id,
                 code: enrollment.check_in_code,
                 method: :manual
               })
               |> Ash.create(tenant: other_workspace.id, actor: moderator)

      assert attendance_count(enrollment.id) == 0
    end
  end

  describe "check_in/4 码定位" do
    test "错码 / payment_pending 报名的码 / 已取消报名的码：统一 attendance_invalid_code" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      free_event = EventFixtures.create_event(workspace, owner)

      deposit_event =
        EventFixtures.create_event(workspace, owner, %{
          deposit_enabled: true,
          deposit_amount_cents: 6900,
          ends_at: EventFixtures.days_from_now(8)
        })

      # 主理人对两场都有核销资格：本组断言只测「码无效」，不掺权限噪声
      moderator = assign_moderator(free_event, workspace, owner, "attendance-code-moderator")
      {:ok, _} = Moderators.assign(deposit_event.id, workspace.id, moderator.id, owner)

      confirmed = create_confirmed_enrollment(free_event)

      learner = Fixtures.register_user("attendance-pending-learner")
      {:ok, pending} = create_enrollment(deposit_event, learner)
      assert pending.status == :payment_pending

      cancelled = create_confirmed_enrollment(free_event)

      assert {:ok, _} =
               cancelled
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner_of(cancelled))

      assert :invalid_code = reason(check_in(free_event, "000000", :manual, moderator))

      assert :invalid_code =
               reason(check_in(deposit_event, pending.check_in_code, :manual, moderator))

      assert :invalid_code =
               reason(check_in(free_event, cancelled.check_in_code, :manual, moderator))

      # 三个失败面都不落行（失败不是「半核销」）
      assert attendance_count(confirmed.id) == 0
      assert attendance_count(pending.id) == 0
      assert attendance_count(cancelled.id) == 0

      # 对照：同场 confirmed 的码仍可核销（证否「整场拒绝」）
      assert {:ok, _} = check_in(free_event, confirmed.check_in_code, :manual, moderator)
    end

    test "跨 Event 用码无效：定位按 (event_id, code)" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event_a = EventFixtures.create_event(workspace, owner, %{title: "A 场"})
      event_b = EventFixtures.create_event(workspace, owner, %{title: "B 场"})
      moderator = assign_moderator(event_a, workspace, owner, "attendance-cross-moderator")
      {:ok, _} = Moderators.assign(event_b.id, workspace.id, moderator.id, owner)

      # 钉死两场码，避免随机同码造成 flake（A 场 135790 / B 场 246801）
      RandomCode.stub_next(fn -> "135790" end)
      enrollment_a = create_confirmed_enrollment(event_a)

      RandomCode.stub_next(fn -> "246801" end)
      enrollment_b = create_confirmed_enrollment(event_b)

      assert enrollment_a.check_in_code == "135790"
      assert enrollment_b.check_in_code == "246801"

      # B 场拿 A 场的码 → 无效；A 场自己的码可用
      assert :invalid_code = reason(check_in(event_b, "135790", :manual, moderator))
      assert attendance_count(enrollment_a.id) == 0
      assert attendance_count(enrollment_b.id) == 0

      assert {:ok, _} = check_in(event_a, "135790", :manual, moderator)
      assert attendance_count(enrollment_a.id) == 1
    end

    test "event 不存在 / event_id 非法：同码返回 attendance_invalid_code" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      moderator = assign_moderator(event, workspace, owner, "attendance-missing-event-mod")

      assert :invalid_code =
               reason(check_in(%{id: Ecto.UUID.generate()}, "123456", :manual, moderator))

      assert :invalid_code = reason(check_in(%{id: "not-a-uuid"}, "123456", :manual, moderator))
    end
  end

  describe "check_in/4 幂等" do
    test "同一报名第二次核销被拒：不落第二行、不重复审计" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      enrollment = create_confirmed_enrollment(event)
      moderator = assign_moderator(event, workspace, owner, "attendance-idem-moderator")

      assert {:ok, _} = check_in(event, enrollment.check_in_code, :manual, moderator)

      # 换核销人、换方式再核销 → 仍是同一报名的第二次核销
      assert :already_checked_in = reason(check_in(event, enrollment.check_in_code, :scan, owner))

      assert attendance_count(enrollment.id) == 1
      assert length(audit_logs(enrollment.id)) == 1
    end

    test "两进程并发核销同一报名：恰一行，败者 attendance_already_checked_in 且无审计副作用" do
      {workspace, event, moderator, enrollment, users} =
        unboxed(fn ->
          admin = Fixtures.platform_admin("attendance-race-admin")
          workspace = Fixtures.create_workspace(admin)
          event = EventFixtures.create_event(workspace, admin)

          moderator = Fixtures.register_user("attendance-race-moderator")
          {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, admin)

          learner = Fixtures.register_user("attendance-race-learner")
          RandomCode.stub_next(fn -> "864209" end)

          {:ok, enrollment} =
            Enrollment
            |> Ash.Changeset.for_create(:create_enrollment, %{
              event_id: event.id,
              user_id: learner.id
            })
            |> Ash.create(tenant: workspace.id, actor: learner)

          {workspace, event, moderator, enrollment, [admin, moderator, learner]}
        end)

      cleanup_on_exit(workspace, event, users)

      barrier = start_supervised!({Barrier, 2})

      results =
        [moderator, moderator]
        |> Enum.map(fn actor ->
          Task.async(fn ->
            unboxed(fn ->
              # 两进程在各自真实连接上对齐后同时发起：FOR UPDATE 串行化 + 唯一索引兜底
              Barrier.arrive(barrier)
              Attendance.check_in(event.id, enrollment.check_in_code, :manual, actor)
            end)
          end)
        end)
        |> Task.await_many(30_000)

      assert {:ok, attendance} = Enum.find(results, &match?({:ok, _}, &1))
      assert attendance.enrollment_id == enrollment.id

      assert :already_checked_in = reason(Enum.find(results, &match?({:error, _}, &1)))

      unboxed(fn ->
        assert attendance_count(enrollment.id) == 1
        # 败者不执行 after_action（LogAdminAction）：审计恰一行
        assert audit_count(enrollment.id) == 1
      end)
    end
  end

  # ── 布置 ──

  defp create_enrollment(%{id: id, workspace_id: workspace_id}, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: id, user_id: user.id})
    |> Ash.create(tenant: workspace_id, actor: user)
  end

  defp create_confirmed_enrollment(event) do
    learner = Fixtures.register_user("attendance-learner")

    {:ok, enrollment} = create_enrollment(event, learner)
    assert enrollment.status == :confirmed
    enrollment
  end

  defp assign_moderator(event, workspace, owner, prefix) do
    moderator = Fixtures.register_user(prefix)
    {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, owner)
    moderator
  end

  defp learner_of(enrollment),
    do: Ash.get!(User, enrollment.user_id, authorize?: false)

  defp check_in(event, code, method, actor),
    do: Attendance.check_in(event.id, code, method, actor)

  # 错误形状解包：Ash 把 BusinessError 收在 %Ash.Error.Invalid{errors: [...]} 内
  defp reason({:error, %Ash.Error.Invalid{errors: errors}}), do: reason_of(errors)
  defp reason({:error, %BusinessError{} = error}), do: reason_of([error])
  defp reason(other), do: other

  defp reason_of(errors) do
    case Enum.find(errors, &match?(%BusinessError{}, &1)) do
      %BusinessError{code: "attendance_invalid_code"} -> :invalid_code
      %BusinessError{code: "attendance_already_checked_in"} -> :already_checked_in
      other -> other
    end
  end

  defp audit_logs(enrollment_id) do
    AdminActionLog
    |> Ash.Query.filter(action == :attendance_check_in and target_id == ^enrollment_id)
    |> Ash.read!(authorize?: false)
  end

  defp attendance_count(enrollment_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM attendances WHERE enrollment_id = $1",
        [enrollment_id && Repo.uuid!(enrollment_id)]
      )

    count
  end

  defp audit_count(enrollment_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM admin_action_logs WHERE action = 'attendance_check_in' AND target_id = $1",
        [Repo.uuid!(enrollment_id)]
      )

    count
  end

  # ── 并发用例布置（OrderEnrollmentLockTest 同款：先释放 sandbox 事务，再 unboxed 真删）──

  defp cleanup_on_exit(workspace, event, users) do
    on_exit(fn ->
      # 先结束 shared sandbox 事务：应用级订阅方/审计写在事务内的 workspaces 外键
      # KEY SHARE 锁不释放，unboxed DELETE workspaces 会阻塞到连接超时（owner Agent
      # 不 kill——DataCase 的 on_exit 仍要 stop_owner，二次 stop 会 :noproc 崩）。
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      unboxed(fn ->
        Repo.query!("DELETE FROM attendances WHERE workspace_id = $1", [Repo.uuid!(workspace.id)])

        Repo.query!(
          "DELETE FROM admin_action_logs WHERE action = 'attendance_check_in' AND metadata->>'event_id' = $1",
          [event.id]
        )

        Repo.query!("DELETE FROM enrollments WHERE event_id = $1", [Repo.uuid!(event.id)])

        Repo.query!("DELETE FROM admission_capacity_ledgers WHERE offering_id = $1", [
          Repo.uuid!(event.id)
        ])

        Repo.query!("DELETE FROM event_moderators WHERE event_id = $1", [Repo.uuid!(event.id)])

        Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN (SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Repo.uuid!(workspace.id)]
        )

        Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!("DELETE FROM events WHERE workspace_id = $1", [Repo.uuid!(workspace.id)])

        Repo.query!(
          "DELETE FROM admin_action_logs WHERE target_type = 'workspace' AND target_id = $1",
          [Repo.uuid!(workspace.id)]
        )

        # #348：workspace seed 落 workflow_definitions（FK）——先清子表再删 workspace
        Repo.query!("DELETE FROM workflow_definitions WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!("DELETE FROM workspaces WHERE id = $1", [Repo.uuid!(workspace.id)])

        Enum.each(users, fn user ->
          Repo.query!("DELETE FROM users WHERE id = $1", [Repo.uuid!(user.id)])
        end)
      end)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
