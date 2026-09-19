defmodule Cgc2046.Mcp.RecruitmentCohortToolsTest do
  @moduledoc """
  招募批次五件工具面测试（create/update/open/close/list；直接调 tool execute/2，
  不走 HTTP；event_tools_test 同款模式）。

  - 授权：plain member / tutor / 非成员对四写件一律 forbidden（非成员撞 Wrapper
    member 门；成员撞工具层 Owner/Admin 判定；workspace admin 与 platform_admin
    放行——批次写面与 GraphQL 同边界，ADR-0001 D6/D7）；
    list_recruitment_cohorts 为 member-only 发现面（成员可读全部状态含 draft）
  - create_recruitment_cohort 直接写生成 draft（不经 pending）；带偏移 ISO8601
    解析为 UTC 落库
  - update/open/close 确认流两段式；非 open/已 open 快速失败不建 pending；
    update 全空参快速失败
  - 第二个 open 撞「同台唯一 open」→ confirm 段稳定业务文案（域
    recruitment_cohort_open_conflict），批次不被打开
  - 跨租户：他工作台 cohort_id ≡ not found（不泄露存在性）
  - ToolCallLog 审计行落库
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.PendingOperation
  alias Cgc2046.Mcp.ToolCallLog

  alias Cgc2046.Mcp.Tools.{
    CloseRecruitmentCohort,
    ConfirmOperation,
    CreateRecruitmentCohort,
    ListRecruitmentCohorts,
    OpenRecruitmentCohort,
    UpdateRecruitmentCohort
  }

  alias Cgc2046.Recruitment.RecruitmentCohort

  require Ash.Query

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode_reply({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp tool_logs_for(user_id, tool_name) do
    ToolCallLog
    |> Ash.Query.filter(user_id == ^user_id and tool == ^tool_name)
    |> Ash.read!(authorize?: false)
  end

  defp pending_count do
    PendingOperation |> Ash.read!(authorize?: false) |> length()
  end

  # create_workspace 需 platform_admin（RBAC，recruitment_resume_test 同款）：
  # 建台者是台 Owner；「workspace admin（非平台管理员）放行」另行 add_member 造
  defp fixture(prefix) do
    owner = Fixtures.platform_admin(prefix)
    workspace = Fixtures.create_workspace(owner)
    {owner, workspace}
  end

  defp draft_cohort(workspace, owner, attrs \\ %{}) do
    attrs =
      Map.merge(%{name: "第 1 批", apply_deadline_at: ~U[2026-10-10 15:59:00Z]}, attrs)

    RecruitmentCohort
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: owner)
  end

  defp open_cohort(workspace, owner, attrs \\ %{}) do
    workspace
    |> draft_cohort(owner, attrs)
    |> Ash.Changeset.for_update(:open, %{}, tenant: workspace.id)
    |> Ash.update!(actor: owner, tenant: workspace.id)
  end

  describe "create_recruitment_cohort（直接写）" do
    test "owner 直接写生成 draft，不经 pending；带偏移 ISO8601 解析为 UTC；审计落行" do
      {owner, workspace} = fixture("s3-co-create-owner")

      assert {:reply, _, _} =
               reply =
               CreateRecruitmentCohort.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "name" => "第 1 批 · 首批志愿者招募",
                   "apply_deadline_at" => "2026-10-10T23:59:00+08:00",
                   "starts_at" => "2026-10-24T00:00:00+08:00"
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "draft"
      assert payload["name"] == "第 1 批 · 首批志愿者招募"
      # 带偏移入参 → UTC 存储（解析单源 admin_initiative_helpers）
      assert payload["apply_deadline_at"] == "2026-10-10T15:59:00Z"
      assert payload["starts_at"] == "2026-10-23T16:00:00Z"
      assert payload["ends_at"] == nil

      assert pending_count() == 0
      cohort = Ash.get!(RecruitmentCohort, payload["cohort_id"], authorize?: false)
      assert cohort.status == :draft
      assert cohort.apply_deadline_at == ~U[2026-10-10 15:59:00Z]

      assert [_log] = tool_logs_for(owner.id, "create_recruitment_cohort")
    end

    test "member / tutor forbidden（工具层判定）；workspace admin 放行；非成员撞 Wrapper 门" do
      {owner, workspace} = fixture("s3-co-create-deny-owner")
      member = Fixtures.register_user("s3-co-create-member")
      Fixtures.add_member(workspace, member)
      tutor = Fixtures.register_user("s3-co-create-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      ws_admin = Fixtures.register_user("s3-co-create-wsadmin")
      Fixtures.add_member(workspace, ws_admin, [:admin])
      outsider = Fixtures.register_user("s3-co-create-outsider")

      params = %{
        "workspace_id" => workspace.id,
        "name" => "越权批次",
        "apply_deadline_at" => "2026-10-10T23:59:00+08:00"
      }

      for {user, expected} <- [
            {member, "forbidden: owner or admin required"},
            {tutor, "forbidden: owner or admin required"},
            {outsider, "forbidden"}
          ] do
        assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                 CreateRecruitmentCohort.execute(params, frame_for(user))

        assert msg =~ expected
      end

      assert pending_count() == 0
      # workspace admin（非平台管理员）经 Rbac.manage?/2 放行——批次写面与
      # GraphQL 同边界（Owner/Admin ∪ platform_admin），不比既有面更严
      assert {:reply, _, _} = CreateRecruitmentCohort.execute(params, frame_for(ws_admin))
      # owner 未被波及（布点断言：门只拦非管理角色）
      assert {:reply, _, _} = CreateRecruitmentCohort.execute(params, frame_for(owner))
    end

    test "platform_admin 非成员同样被 member 门拦（双面契约：豁免只能走显式族，
    member-only 门不放宽）" do
      {_owner, workspace} = fixture("s3-co-create-pa-target")
      platform = Fixtures.platform_admin("s3-co-create-pa")
      assert platform.is_platform_admin

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               CreateRecruitmentCohort.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "name" => "平台管理员非成员",
                   "apply_deadline_at" => "2026-10-10T23:59:00+08:00"
                 },
                 frame_for(platform)
               )

      # Wrapper 双面契约（S2 裁决）：member-only 门不含 platform_admin 豁免；
      # 平台管理员操作台内批次须经台成员身份（Owner/Admin），或未来显式新族
      assert msg =~ "not a member of workspace"
      assert pending_count() == 0
    end

    test "apply_deadline_at 非法格式 → Ash cast 报错（经 Errors.message 折叠，不建 pending）" do
      {owner, workspace} = fixture("s3-co-create-badts")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               CreateRecruitmentCohort.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "name" => "坏时间",
                   "apply_deadline_at" => "not-a-date"
                 },
                 frame_for(owner)
               )

      assert msg =~ "apply_deadline_at"
      assert pending_count() == 0
    end
  end

  describe "update_recruitment_cohort（确认流）" do
    test "两段式：改名称与截止，confirm 落库；第一段不落库" do
      {owner, workspace} = fixture("s3-co-upd-owner")
      cohort = draft_cohort(workspace, owner)

      assert {:reply, _, _} =
               reply =
               UpdateRecruitmentCohort.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "cohort_id" => cohort.id,
                   "name" => "第 1 批（改）",
                   "apply_deadline_at" => "2026-10-12T23:59:00+08:00"
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ cohort.id
      assert payload["summary"] =~ "name"
      assert payload["summary"] =~ "第 1 批（改）"
      assert payload["summary"] =~ "apply_deadline_at"

      assert Ash.get!(RecruitmentCohort, cohort.id, authorize?: false).name == "第 1 批"

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["name"] == "第 1 批（改）"
      assert confirmed["result"]["apply_deadline_at"] == "2026-10-12T15:59:00Z"

      updated = Ash.get!(RecruitmentCohort, cohort.id, authorize?: false)
      assert updated.name == "第 1 批（改）"
      assert updated.apply_deadline_at == ~U[2026-10-12 15:59:00Z]

      [log] = tool_logs_for(owner.id, "update_recruitment_cohort")
      assert log.result_status == :needs_confirmation
    end

    test "全空参 → 报错不建 pending" do
      {owner, workspace} = fixture("s3-co-upd-empty-owner")
      cohort = draft_cohort(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateRecruitmentCohort.execute(
                 %{"workspace_id" => workspace.id, "cohort_id" => cohort.id},
                 frame_for(owner)
               )

      assert msg =~ "nothing to update"
      assert pending_count() == 0
    end

    test "member forbidden（工具层判定）" do
      {owner, workspace} = fixture("s3-co-upd-deny-owner")
      cohort = draft_cohort(workspace, owner)
      member = Fixtures.register_user("s3-co-upd-member")
      Fixtures.add_member(workspace, member)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateRecruitmentCohort.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "cohort_id" => cohort.id,
                   "name" => "越权改名"
                 },
                 frame_for(member)
               )

      assert msg =~ "forbidden: owner or admin required"
      assert pending_count() == 0
      assert Ash.get!(RecruitmentCohort, cohort.id, authorize?: false).name == "第 1 批"
    end
  end

  describe "open_recruitment_cohort（确认流）" do
    test "draft → open（两段；第一段仍 draft）" do
      {owner, workspace} = fixture("s3-co-open-owner")
      cohort = draft_cohort(workspace, owner)

      assert {:reply, _, _} =
               reply =
               OpenRecruitmentCohort.execute(
                 %{"workspace_id" => workspace.id, "cohort_id" => cohort.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ cohort.id
      assert payload["summary"] =~ "draft → open"
      assert payload["summary"] =~ "申请入口开启"

      assert Ash.get!(RecruitmentCohort, cohort.id, authorize?: false).status == :draft

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["status"] == "open"
      assert Ash.get!(RecruitmentCohort, cohort.id, authorize?: false).status == :open
    end

    test "已 open 快速失败（不建 pending）" do
      {owner, workspace} = fixture("s3-co-open-twice-owner")
      cohort = open_cohort(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               OpenRecruitmentCohort.execute(
                 %{"workspace_id" => workspace.id, "cohort_id" => cohort.id},
                 frame_for(owner)
               )

      assert msg =~ "cannot open from status=open"
      assert pending_count() == 0
    end

    test "第二个 open 撞「同台唯一 open」→ confirm 段稳定冲突文案，目标批次未 open" do
      {owner, workspace} = fixture("s3-co-open-conflict-owner")
      open_cohort(workspace, owner, %{name: "先开的批"})
      second = draft_cohort(workspace, owner, %{name: "后开的批"})

      assert {:reply, _, _} =
               reply =
               OpenRecruitmentCohort.execute(
                 %{"workspace_id" => workspace.id, "cohort_id" => second.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      assert msg =~ "another cohort is already open"
      # effect 失败不留 confirmed-but-no-effect：批次仍 draft，可修正后重试
      assert Ash.get!(RecruitmentCohort, second.id, authorize?: false).status == :draft
    end

    test "member forbidden（工具层判定）" do
      {owner, workspace} = fixture("s3-co-open-deny-owner")
      cohort = draft_cohort(workspace, owner)
      member = Fixtures.register_user("s3-co-open-member")
      Fixtures.add_member(workspace, member)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               OpenRecruitmentCohort.execute(
                 %{"workspace_id" => workspace.id, "cohort_id" => cohort.id},
                 frame_for(member)
               )

      assert msg =~ "forbidden: owner or admin required"
      assert pending_count() == 0
      assert Ash.get!(RecruitmentCohort, cohort.id, authorize?: false).status == :draft
    end
  end

  describe "close_recruitment_cohort（确认流）" do
    test "open → closed（两段；摘要含在途申请语义；closed 可重开）" do
      {owner, workspace} = fixture("s3-co-close-owner")
      cohort = open_cohort(workspace, owner)

      assert {:reply, _, _} =
               reply =
               CloseRecruitmentCohort.execute(
                 %{"workspace_id" => workspace.id, "cohort_id" => cohort.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ "open → closed"
      assert payload["summary"] =~ "在途申请照常走完"

      assert Ash.get!(RecruitmentCohort, cohort.id, authorize?: false).status == :open

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["status"] == "closed"
      assert Ash.get!(RecruitmentCohort, cohort.id, authorize?: false).status == :closed
    end

    test "draft / closed 快速失败（不建 pending）" do
      {owner, workspace} = fixture("s3-co-close-fast-owner")
      draft = draft_cohort(workspace, owner)

      closed =
        open_cohort(workspace, owner, %{name: "另一批"})
        |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id)
        |> Ash.update!(actor: owner, tenant: workspace.id)

      for {cohort, expected} <- [
            {draft, "cannot close from status=draft"},
            {closed, "cannot close from status=closed"}
          ] do
        assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                 CloseRecruitmentCohort.execute(
                   %{"workspace_id" => workspace.id, "cohort_id" => cohort.id},
                   frame_for(owner)
                 )

        assert msg =~ expected
      end

      assert pending_count() == 0
    end
  end

  describe "list_recruitment_cohorts（member-only 发现面）" do
    test "member 可读全部状态（含 draft），status 过滤；倒序" do
      {owner, workspace} = fixture("s3-co-list-owner")
      member = Fixtures.register_user("s3-co-list-member")
      Fixtures.add_member(workspace, member)

      # 造数顺序避「同台唯一 open」：closed 批先建 draft 再经域 close（域 :close
      # 无状态前提），open 批在无其他 open 时开放
      closed_draft = draft_cohort(workspace, owner, %{name: "closed 批"})
      _open = open_cohort(workspace, owner, %{name: "open 批"})

      _closed =
        closed_draft
        |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id)
        |> Ash.update!(actor: owner, tenant: workspace.id)

      _draft = draft_cohort(workspace, owner, %{name: "draft 批"})

      assert {:reply, _, _} =
               reply =
               ListRecruitmentCohorts.execute(
                 %{"workspace_id" => workspace.id},
                 frame_for(member)
               )

      payload = decode_reply(reply)
      assert payload["count"] == 3
      # 建批顺序 closed 批 → open 批 → draft 批；inserted_at 倒序 = 最新在前
      assert Enum.map(payload["cohorts"], & &1["name"]) == ["draft 批", "open 批", "closed 批"]

      assert {:reply, _, _} =
               reply =
               ListRecruitmentCohorts.execute(
                 %{"workspace_id" => workspace.id, "status" => "open"},
                 frame_for(member)
               )

      payload = decode_reply(reply)
      assert payload["count"] == 1
      assert hd(payload["cohorts"])["status"] == "open"
      assert hd(payload["cohorts"])["apply_deadline_at"] == "2026-10-10T15:59:00Z"
    end

    test "status 非法值报错带清单" do
      {owner, workspace} = fixture("s3-co-list-badstatus-owner")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListRecruitmentCohorts.execute(
                 %{"workspace_id" => workspace.id, "status" => "nope"},
                 frame_for(owner)
               )

      assert msg =~ "invalid status"
      assert msg =~ "draft|open|closed"
    end

    test "非成员 forbidden（Wrapper 门）" do
      {_owner, workspace} = fixture("s3-co-list-outsider-target")
      outsider = Fixtures.register_user("s3-co-list-outsider")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListRecruitmentCohorts.execute(
                 %{"workspace_id" => workspace.id},
                 frame_for(outsider)
               )

      assert msg =~ "forbidden"
    end
  end

  describe "跨租户" do
    test "他工作台 cohort_id ≡ not found（update/open/close 不泄露存在性）" do
      {owner_a, workspace_a} = fixture("s3-co-x-owner-a")
      {owner_b, workspace_b} = fixture("s3-co-x-owner-b")
      cohort_b = open_cohort(workspace_b, owner_b)

      for {module, extra} <- [
            {UpdateRecruitmentCohort, %{"name" => "越租户改写"}},
            {OpenRecruitmentCohort, %{}},
            {CloseRecruitmentCohort, %{}}
          ] do
        assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                 module.execute(
                   Map.merge(
                     %{"workspace_id" => workspace_a.id, "cohort_id" => cohort_b.id},
                     extra
                   ),
                   frame_for(owner_a)
                 )

        assert msg =~ "recruitment cohort not found"
      end

      assert pending_count() == 0
      assert Ash.get!(RecruitmentCohort, cohort_b.id, authorize?: false).status == :open
    end
  end
end
