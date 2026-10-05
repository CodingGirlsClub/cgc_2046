defmodule Cgc2046.McpToolTiers do
  @moduledoc """
  MCP 工具可见性分层的精确名单（#1085，测试事实源）。

  名单是**人工钉死**的预期，不从被测实现（各工具的 `scopes:` 声明）推导：新增工具必须在
  这里显式归层，否则 `tool_scopes_test` 红（同 `wrapper_gate_test` 的名单纪律）。分层口径
  与「可见面不比授权更严」原则见 `Cgc2046.Mcp.Scopes` 与 ADR-0021。

  四个互斥名单的并集 = 全部注册工具；`visible_for/1` 给出各调用者层级**累计**可见的名单。
  """

  # Owner/Admin 层：工具层硬门是 Rbac.manage? / Prep.manage?（delete_course / delete_event 为
  # Owner ∪ 平台管理员，平台管理员经 scope 级联拿到）
  @workspace_admin ~w(
    approve_join_request assign_event_moderator assign_prep_tutor assign_roles
    batch_create_events cancel_course cancel_event close_course close_event
    close_recruitment_cohort confirm_enrollment create_course create_event
    create_recruitment_cohort delete_course delete_event launch_course launch_event
    list_attendances list_enrollments list_join_requests list_workspace_orders
    open_recruitment_cohort preview_initiative_mount refund_order reject_enrollment
    remove_event_moderator retry_refund update_course update_event update_join_policy
    update_prep_policy update_recruitment_cohort waive_payment
  )

  # tutor 层：工具层硬门是 Rbac.staff?（tutor ∪ Owner/Admin）
  @tutor ~w(
    claim_prep_authoring get_course_content get_course_learning_analytics
    save_course_content
  )

  # 平台治理层：现有 meta: %{membership: :platform_admin} 的 28 个
  @platform_admin ~w(
    admin_approve_workspace_application admin_cancel_initiative admin_close_initiative
    admin_create_initiative admin_create_workspace admin_demote_user admin_get_initiative
    admin_get_wish admin_list_audit_logs admin_list_initiatives
    admin_list_reconciliation_findings admin_list_users admin_list_wishes
    admin_list_workspace_applications admin_list_workspaces admin_open_initiative
    admin_promote_user admin_reassign_workspace_owner admin_reject_workspace_application
    admin_resend_flashback_outreach admin_send_flashback_outreach admin_soft_delete_wish
    admin_soft_delete_wish_comment admin_update_initiative admin_upsert_initiative_rule
    list_acquisition_stats list_flashback_stats unforfeit_order
  )

  # 全员可见：其余全部。含 5 个「实际授权比描述宽」的工具（授权不变，收窄另案跟踪）：
  # create_invitation（volunteer 可发邀请）、list_event_moderators（活动主理人可读）、
  # approve_prep / override_prep_gate / request_changes_prep（未指定 reviewer 时任何成员）；
  # 另含两个 prep 提交工具（授权 = 被指派 tutor ∨ Owner/Admin，被指派者可能失去 tutor
  # 角色——评审 T3：只推「被指派 tutor」会让他们 list_my_tasks 看到任务但调不动工具）。
  @all_visible ~w(
    approve_prep cancel_operation confirm_operation create_enrollment create_invitation
    discover_offerings get_course_revision get_enrollment_summary get_learning_state
    get_my_enrollments get_order_status get_prep_status get_public_initiative
    get_public_offering get_role_playbook get_step_output get_workflow
    get_workspace_context list_event_moderators list_members list_my_tasks
    list_my_workspaces list_public_initiatives list_public_offerings
    list_recruitment_cohorts list_workspace_courses list_workspace_events
    override_prep_gate request_changes_prep save_step_output start_learning_run
    submit_learning_attempt submit_prep_for_check submit_prep_quality_report
  )

  def all_visible, do: Enum.sort(@all_visible)
  def tutor, do: Enum.sort(@tutor)
  def workspace_admin, do: Enum.sort(@workspace_admin)
  def platform_admin, do: Enum.sort(@platform_admin)

  @doc "各调用者层级累计可见的工具名（已排序）。"
  @spec visible_for(:learner | :tutor | :workspace_admin | :platform_admin) :: [String.t()]
  def visible_for(:learner), do: all_visible()
  def visible_for(:tutor), do: Enum.sort(@all_visible ++ @tutor)
  def visible_for(:workspace_admin), do: Enum.sort(@all_visible ++ @tutor ++ @workspace_admin)

  def visible_for(:platform_admin),
    do: Enum.sort(@all_visible ++ @tutor ++ @workspace_admin ++ @platform_admin)
end
