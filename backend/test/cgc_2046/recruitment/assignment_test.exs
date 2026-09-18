defmodule Cgc2046.Recruitment.AssignmentTest do
  @moduledoc """
  R15 分配副作用验收（Covers AE4）：assign 流转在同一事务内完成「邀请入台 +
  角色映射 + 主理人 EventModerator 指派」，失败整体回滚（申请保持 training）。

  与 U3 的 workflow_flow_test 分工：那边验状态机与 run 镜像；这边验跨域副作用
  （Accounts 成员/角色 + Events 指派）。分配前的「申请人不是台成员」是刻意的
  fixture 前提——R15 的「先邀请入台再指派」在分配时点成立。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.EventModerator
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Recruitment.{Assignment, RecruitmentCohort, VolunteerApplication}

  setup do
    creator = Fixtures.platform_admin("assignment-creator")
    workspace = Fixtures.create_workspace(creator)

    owner = Fixtures.register_user("assignment-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    # 申请人刻意不是台成员：R15 要求分配时才邀请入台
    applicant = Fixtures.register_user("assignment-applicant")
    cohort = open_cohort(workspace, owner, "第 1 批")

    %{
      creator: creator,
      workspace: workspace,
      owner: owner,
      applicant: applicant,
      cohort: cohort
    }
  end

  describe "AE4：主理人分配（有场次）" do
    test "assign → 申请人入台（volunteer 角色）+ EventModerator 指派", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort, creator: creator} = ctx
      event = EventFixtures.create_event(ws, creator)

      {:ok, application} = apply_for(ws, applicant, cohort, %{position: :event_moderator})
      {:ok, application} = advance(ws, owner, application, :advance_to_interview)
      {:ok, application} = advance(ws, owner, application, :advance_to_training)

      refute member?(ws, applicant), "fixture 前提：分配前申请人不是台成员"

      {:ok, assigned} =
        advance(ws, owner, application, :assign, %{assigned_event_id: event.id})

      assert assigned.status == :assigned

      # ① 入台 + 角色（KTD4：场次主理人 → volunteer）
      assert member?(ws, applicant)
      assert roles_of(ws, applicant) == ["volunteer"]

      # ② EventModerator 指派（成员前提在上一步之后）
      assert moderator?(ws, event.id, applicant)
    end
  end

  describe "教程研究员分配（无场次）" do
    test "assign（无 event）→ tutor 角色、无任何 EventModerator", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      {:ok, application} = apply_for(ws, applicant, cohort, %{position: :tutor})
      {:ok, application} = advance(ws, owner, application, :advance_to_interview)
      {:ok, application} = advance(ws, owner, application, :advance_to_training)

      {:ok, assigned} =
        advance(ws, owner, application, :assign, %{assignment_note: "课程 A 第 1-3 章"})

      assert assigned.status == :assigned
      refute is_nil(assigned.assignment_note)

      # KTD4：教程研究员 → tutor；无场次指派（课程任务只落申请行）
      assert member?(ws, applicant)
      assert roles_of(ws, applicant) == ["tutor"]
      assert moderator_rows(ws, applicant) == []
    end
  end

  describe "失败整体回滚（fail-closed）" do
    test "assigned_event_id 指向不存在的场次 → assign 失败、申请保持 training、无半成品", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      {:ok, application} = apply_for(ws, applicant, cohort, %{position: :event_moderator})
      {:ok, application} = advance(ws, owner, application, :advance_to_interview)
      {:ok, application} = advance(ws, owner, application, :advance_to_training)

      missing_event_id = Ash.UUID.generate()

      assert {:error, error} =
               advance(ws, owner, application, :assign, %{assigned_event_id: missing_event_id})

      assert %Cgc2046.Errors.BusinessError{code: "volunteer_application_assignment_failed"} =
               find_business_error(error)

      # 回滚：状态未推进，入台也未发生（绝不落「已分配但没入台/没指派」的半成品）
      reloaded = Ash.get!(VolunteerApplication, application.id, tenant: ws.id, authorize?: false)
      assert reloaded.status == :training
      refute member?(ws, applicant)
    end
  end

  describe "映射单源" do
    test "roles_for/1 与 KTD4 逐条一致", _ctx do
      assert Assignment.roles_for(:event_moderator) == [:volunteer]
      assert Assignment.roles_for(:coach) == [:volunteer]
      assert Assignment.roles_for(:tutor) == [:tutor]
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp open_cohort(workspace, actor, name) do
    attrs = %{
      name: name,
      apply_deadline_at: DateTime.add(DateTime.utc_now(), 7, :day)
    }

    {:ok, cohort} =
      RecruitmentCohort
      |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id, actor: actor)
      |> Ash.create(tenant: workspace.id, actor: actor)

    {:ok, open} =
      cohort
      |> Ash.Changeset.for_update(:open, %{}, tenant: workspace.id, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    open
  end

  defp apply_for(workspace, actor, cohort, attrs) do
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
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id, actor: actor)
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  defp advance(workspace, actor, application, action, args \\ %{}) do
    application
    |> Ash.Changeset.for_update(action, args, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp member?(workspace, user) do
    MembershipContext.role_names(user, workspace.id) != []
  end

  defp roles_of(workspace, user) do
    user
    |> MembershipContext.role_names(workspace.id)
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp moderator_rows(workspace, user) do
    EventModerator
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(tenant: workspace.id, authorize?: false)
  end

  defp moderator?(workspace, event_id, user) do
    Enum.any?(moderator_rows(workspace, user), &(&1.event_id == event_id))
  end

  defp find_business_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.find(errors, fn
      %Cgc2046.Errors.BusinessError{} -> true
      _ -> false
    end)
  end

  defp find_business_error(%Cgc2046.Errors.BusinessError{} = error), do: error
end
