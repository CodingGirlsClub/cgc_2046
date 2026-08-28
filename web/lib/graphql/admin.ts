import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationError } from "./shared";
import type { JoinPolicy } from "./workspace";

/**
 * Platform Admin Dashboard GraphQL 契约（对齐后端 Phase 5 schema commit ca89719）。
 *
 * 关键约定：
 * - listUsers / listWorkspaces / listWorkspaceApplications 返回裸对象数组，
 *   分页参数 first（默认 50）/ after（offset 字符串）。
 * - listWorkflowRuns 复用 workflow.ts 既有 LIST_WORKFLOW_RUNS（Phase 5 决定不手写，
 *   WorkflowRun 自动 query + platform_admin read policy）。
 * - approve/rejectWorkspaceApplication + createWorkspace 为 AshGraphql 自动生成，
 *   返回标准 { result, errors } 信封；createWorkspace 的 metadata 携带
 *   ownerInvitationToken（仅创建时返回一次）。
 */

/* ---------------- 类型（对齐 backend/priv/graphql/schema.graphql） ---------------- */

export interface AdminUser {
	id: string;
	email?: string | null;
	displayName?: string | null;
	isPlatformAdmin: boolean;
	insertedAt: string;
	workspaceMembershipCount?: number | null;
}

/** 与 workspace.ts 的 JoinPolicy 同构（单源：workspace.ts） */
export type AdminJoinPolicy = JoinPolicy;

export interface AdminWorkspace {
	id: string;
	slug: string;
	name: string;
	joinPolicy: AdminJoinPolicy;
	sponsorshipEnabled: boolean;
	insertedAt: string;
	memberCount: number;
}

export type AdminApplicationStatus = "pending" | "approved" | "rejected" | "expired";

export interface AdminWorkspaceApplication {
	id: string;
	applicantId: string;
	name: string;
	slug: string;
	purpose: string;
	status: AdminApplicationStatus;
	rejectionReason?: string | null;
	/** 审批处理人 ID（status = approved 时由后端写入） */
	approvedBy?: string | null;
	approvedAt?: string | null;
	/** 拒绝处理人 ID（status = rejected 时由后端写入） */
	rejectedBy?: string | null;
	rejectedAt?: string | null;
	insertedAt: string;
}

export interface AdminToolCallLog {
	id: string;
	userId: string;
	tool: string;
	resultStatus: string;
	errorMessage?: string | null;
	latencyMs?: number | null;
	insertedAt: string;
}

export interface AdminPendingOperation {
	id: string;
	userId: string;
	tool: string;
	summary: string;
	status: string;
	insertedAt: string;
}

export interface AdminSignalLog {
	id: string;
	workspaceId: string;
	signalType: string;
	insertedAt: string;
}

/** 平台治理操作审计日志（listAdminActionLogs） */
export interface AdminActionLog {
	id: string;
	/** 操作者 ID；null = 系统/CLI 触发 */
	actorId: string | null;
	/** 枚举值：workspace_create | application_approve | application_reject | admin_promote | admin_demote | owner_reassign | owner_invitation_cancel */
	action: string;
	/** 目标类型：workspace | workspace_application | user */
	targetType: string;
	targetId: string;
	/** v1 恒为 "success" */
	result: string;
	insertedAt: string;
}

/** promoteUser/demoteUser 返回（set_platform_admin 结果信封） */
export interface AdminUserPayload {
	id: string | null;
	email?: string | null;
	isPlatformAdmin?: boolean | null;
	errors: MutationError[];
}

/** admin 列表查询通用分页参数（after = offset 字符串） */
export interface AdminListArgs {
	first?: number;
	after?: string;
}

/** #117 审计筛选公共时间范围变量（ISO8601 串；null/undefined = 不过滤） */
export interface AuditTimeRangeVars {
	insertedAfter?: string | null;
	insertedBefore?: string | null;
}

/* ---------------- 真实 query / mutation ---------------- */

export const LIST_USERS: TypedDocumentNode<
	{ listUsers: AdminUser[] },
	{ search?: string | null; first?: number; after?: string } & AdminListArgs
> = gql`
  query ListUsers($search: String, $first: Int, $after: String) {
    listUsers(search: $search, first: $first, after: $after) {
      id
      email
      displayName
      isPlatformAdmin
      insertedAt
      workspaceMembershipCount
    }
  }
`;

export const LIST_WORKSPACES: TypedDocumentNode<
	{ listWorkspaces: AdminWorkspace[] },
	{ search?: string | null; first?: number; after?: string } & AdminListArgs
> = gql`
  query ListWorkspaces($search: String, $first: Int, $after: String) {
    listWorkspaces(search: $search, first: $first, after: $after) {
      id
      slug
      name
      joinPolicy
      sponsorshipEnabled
      insertedAt
      memberCount
    }
  }
`;

export const LIST_WORKSPACE_APPLICATIONS: TypedDocumentNode<
	{ listWorkspaceApplications: AdminWorkspaceApplication[] },
	{ status?: string | null; first?: number; after?: string } & AdminListArgs
> = gql`
  query ListWorkspaceApplications($status: String, $first: Int, $after: String) {
    listWorkspaceApplications(status: $status, first: $first, after: $after) {
      id
      applicantId
      name
      slug
      purpose
      status
      rejectionReason
      approvedBy
      approvedAt
      rejectedBy
      rejectedAt
      insertedAt
    }
  }
`;

export const MY_WORKSPACE_APPLICATIONS: TypedDocumentNode<
	{ myWorkspaceApplications: AdminWorkspaceApplication[] },
	Record<string, never>
> = gql`
  query MyWorkspaceApplications {
    myWorkspaceApplications {
      id
      applicantId
      name
      slug
      purpose
      status
      rejectionReason
      insertedAt
    }
  }
`;

export const LIST_TOOL_CALL_LOGS: TypedDocumentNode<
	{ listToolCallLogs: AdminToolCallLog[] },
	{
		workspaceId?: string | null;
		status?: string | null;
		first?: number;
		after?: string;
	} & AdminListArgs &
		AuditTimeRangeVars
> = gql`
  query ListToolCallLogs(
    $workspaceId: ID
    $status: String
    $insertedAfter: DateTime
    $insertedBefore: DateTime
    $first: Int
    $after: String
  ) {
    listToolCallLogs(
      workspaceId: $workspaceId
      status: $status
      insertedAfter: $insertedAfter
      insertedBefore: $insertedBefore
      first: $first
      after: $after
    ) {
      id
      userId
      tool
      resultStatus
      errorMessage
      latencyMs
      insertedAt
    }
  }
`;

export const LIST_PENDING_OPERATIONS: TypedDocumentNode<
	{ listPendingOperations: AdminPendingOperation[] },
	{
		workspaceId?: string | null;
		status?: string | null;
		first?: number;
		after?: string;
	} & AdminListArgs &
		AuditTimeRangeVars
> = gql`
  query ListPendingOperations(
    $workspaceId: ID
    $status: String
    $insertedAfter: DateTime
    $insertedBefore: DateTime
    $first: Int
    $after: String
  ) {
    listPendingOperations(
      workspaceId: $workspaceId
      status: $status
      insertedAfter: $insertedAfter
      insertedBefore: $insertedBefore
      first: $first
      after: $after
    ) {
      id
      userId
      tool
      summary
      status
      insertedAt
    }
  }
`;

export const LIST_SIGNAL_LOGS: TypedDocumentNode<
	{ listSignalLogs: AdminSignalLog[] },
	{
		workspaceId?: string | null;
		signalType?: string | null;
		first?: number;
		after?: string;
	} & AdminListArgs &
		AuditTimeRangeVars
> = gql`
  query ListSignalLogs(
    $workspaceId: ID
    $signalType: String
    $insertedAfter: DateTime
    $insertedBefore: DateTime
    $first: Int
    $after: String
  ) {
    listSignalLogs(
      workspaceId: $workspaceId
      signalType: $signalType
      insertedAfter: $insertedAfter
      insertedBefore: $insertedBefore
      first: $first
      after: $after
    ) {
      id
      workspaceId
      signalType
      insertedAt
    }
  }
`;

export const LIST_ADMIN_ACTION_LOGS: TypedDocumentNode<
	{ listAdminActionLogs: AdminActionLog[] },
	{ action?: string | null; first?: number; after?: string } & AdminListArgs &
		AuditTimeRangeVars
> = gql`
  query ListAdminActionLogs(
    $action: String
    $insertedAfter: DateTime
    $insertedBefore: DateTime
    $first: Int
    $after: String
  ) {
    listAdminActionLogs(
      action: $action
      insertedAfter: $insertedAfter
      insertedBefore: $insertedBefore
      first: $first
      after: $after
    ) {
      id
      actorId
      action
      targetType
      targetId
      result
      insertedAt
    }
  }
`;

/** E-10 #125 对账扫描发现（rule/entityType 为后端 atom 枚举的字符串形态） */
export interface AdminReconciliationFinding {
	id: string;
	rule: string;
	entityType: string;
	entityId: string;
	workspaceId?: string | null;
	firstSeenAt: string;
	lastSeenAt: string;
	insertedAt: string;
}

export const RECONCILIATION_FINDINGS: TypedDocumentNode<
	{ reconciliationFindings: AdminReconciliationFinding[] },
	{
		rule?: string | null;
		entityType?: string | null;
		workspaceId?: string | null;
		first?: number;
		after?: string;
	} & AdminListArgs
> = gql`
  query ReconciliationFindings(
    $rule: String
    $entityType: String
    $workspaceId: ID
    $first: Int
    $after: String
  ) {
    reconciliationFindings(
      rule: $rule
      entityType: $entityType
      workspaceId: $workspaceId
      first: $first
      after: $after
    ) {
      id
      rule
      entityType
      entityId
      workspaceId
      firstSeenAt
      lastSeenAt
      insertedAt
    }
  }
`;

/** 对账规则枚举 → 中文标签（值 = 后端 rule atom 字符串；未知值回退原串） */
export const RECONCILIATION_RULE_LABEL: Record<string, string> = {
	confirmed_enrollment_without_run: "labels.reconRule.confirmed_enrollment_without_run",
	pending_without_deadline: "labels.reconRule.pending_without_deadline",
	active_sponsorship_signal_dead: "labels.reconRule.active_sponsorship_signal_dead",
	open_entity_without_research_definition: "labels.reconRule.open_entity_without_research_definition",
	nonterminal_research_run_for_closed_entity: "labels.reconRule.nonterminal_research_run_for_closed_entity",
	dead_letter_job: "labels.reconRule.dead_letter_job",
	learning_run_stalled: "labels.reconRule.learning_run_stalled",
	open_offering_without_ledger: "labels.reconRule.open_offering_without_ledger",
	ledger_occupancy_mismatch: "labels.reconRule.ledger_occupancy_mismatch",
	capacity_projection_drift: "labels.reconRule.capacity_projection_drift",
	occupancy_exceeds_capacity: "labels.reconRule.occupancy_exceeds_capacity",
};

/** 对账实体类型 → 中文标签 */
export const RECONCILIATION_ENTITY_LABEL: Record<string, string> = {
	enrollment: "labels.reconEntity.enrollment",
	sponsorship: "labels.reconEntity.sponsorship",
	join_request: "labels.reconEntity.join_request",
	workspace_application: "labels.reconEntity.workspace_application",
	event: "labels.reconEntity.event",
	course: "labels.reconEntity.course",
	oban_job: "Oban Job",
	workflow_run: "Workflow Run",
};

/** approveWorkspaceApplication 的 result 子集（审批后状态） */
export interface ApproveApplicationResultData {
	result: { id: string; status: AdminApplicationStatus } | null;
	errors: MutationError[];
}

export const APPROVE_WORKSPACE_APPLICATION: TypedDocumentNode<
	{ approveWorkspaceApplication: ApproveApplicationResultData },
	{ id: string }
> = gql`
  mutation ApproveWorkspaceApplication($id: ID!) {
    approveWorkspaceApplication(id: $id) {
      result {
        id
        status
      }
      errors {
        message
        code
      }
    }
  }
`;

export interface RejectApplicationResultData {
	result: {
		id: string;
		status: AdminApplicationStatus;
		rejectionReason?: string | null;
	} | null;
	errors: MutationError[];
}

export const REJECT_WORKSPACE_APPLICATION: TypedDocumentNode<
	{ rejectWorkspaceApplication: RejectApplicationResultData },
	{ id: string; input: { rejectionReason?: string | null } }
> = gql`
  mutation RejectWorkspaceApplication($id: ID!, $input: RejectWorkspaceApplicationInput) {
    rejectWorkspaceApplication(id: $id, input: $input) {
      result {
        id
        status
        rejectionReason
      }
      errors {
        message
        code
      }
    }
  }
`;

/** 申请创建工作台（R6 /apply 表单；applicantId 由 createApplication 自动注入） */
export interface CreateWorkspaceApplicationInput {
	name: string;
	slug: string;
	purpose: string;
	/** 申请人 ID（后端 required；由 createApplication 内部 fetchCurrentProfile 取） */
	applicantId: string;
}

export interface CreateWorkspaceApplicationResultData {
	result: AdminWorkspaceApplication | null;
	errors: MutationError[];
}

export const CREATE_WORKSPACE_APPLICATION: TypedDocumentNode<
	{ createWorkspaceApplication: CreateWorkspaceApplicationResultData },
	{ input: CreateWorkspaceApplicationInput }
> = gql`
  mutation CreateWorkspaceApplication($input: CreateWorkspaceApplicationInput!) {
    createWorkspaceApplication(input: $input) {
      result {
        id
        applicantId
        name
        slug
        purpose
        status
        rejectionReason
      }
      errors {
        message
        code
      }
    }
  }
`;

export const PROMOTE_USER: TypedDocumentNode<
	{ promoteUser: AdminUserPayload | null },
	{ id: string }
> = gql`
  mutation PromoteUser($id: ID!) {
    promoteUser(id: $id) {
      id
      email
      isPlatformAdmin
      errors {
        message
        code
      }
    }
  }
`;

export const DEMOTE_USER: TypedDocumentNode<
	{ demoteUser: AdminUserPayload | null },
	{ id: string }
> = gql`
  mutation DemoteUser($id: ID!) {
    demoteUser(id: $id) {
      id
      email
      isPlatformAdmin
      errors {
        message
        code
      }
    }
  }
`;

/* ---------------- 展示辅助 ---------------- */

export const APPLICATION_STATUS_LABEL: Record<AdminApplicationStatus, string> = {
	pending: "labels.applicationStatus.pending",
	approved: "labels.applicationStatus.approved",
	rejected: "labels.applicationStatus.rejected",
	expired: "labels.applicationStatus.expired",
};

export const APPLICATION_STATUS_CLASS: Record<AdminApplicationStatus, string> = {
	pending: "l-badge l-badge-pending",
	approved: "l-badge l-badge-success",
	rejected: "l-badge l-badge-danger",
	expired: "l-badge l-badge-muted",
};
