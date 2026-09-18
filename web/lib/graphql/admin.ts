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
 * - workflow audit 走 workflow.ts 的 PLATFORM_WORKFLOW_AUDIT：自定义脱敏根 query
 *   platformWorkflowAudit（仅平台管理员可读；只回运行元数据，无 facts/输入快照）。
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

export interface AdminInitiative {
	id: string; name: string; slug: string; hashtag?: string | null; description?: string | null;
	status: string; windowStartsAt?: string | null; windowEndsAt?: string | null;
	eventCount?: number | null; confirmedCount?: number | null;
	rules?: AdminInitiativeRule[];
	/** #595 挂载场全量清单（仅 getInitiative 取；列表 query 刻意不取，避免 N+1） */
	mountedEvents?: AdminInitiativeMountedEvent[] | null;
}

/**
 * #595 Initiative 挂载场读投影（对齐 SDL `AdminInitiativeMountedEvent`）。
 *
 * 口径要点：不过滤 visibility（workspace-only 场同样被锁死规则改写）、
 * 不过滤 status（draft/open/终态全在）、`confirmedCount` 是 events 展示投影
 * 列（权威计数在名额账本，可能滞后一拍）。
 */
export interface AdminInitiativeMountedEvent {
	id: string;
	initiativeId: string;
	slug: string;
	title: string;
	status: string;
	startsAt?: string | null;
	registrationDeadline?: string | null;
	/** 结构化场地 JSON 串（JsonString）；nil = 线上或未定 */
	venue?: string | null;
	workspaceId: string;
	workspaceName: string;
	confirmedCount: number;
	pricingEnabled: boolean;
	depositEnabled: boolean;
	depositAmountCents?: number | null;
	minAge?: number | null;
	minParticipants?: number | null;
}

export interface AdminInitiativeRule {
	id: string; initiativeId: string; key: string; valueJson: string; locked: boolean;
}

export const LIST_INITIATIVES: TypedDocumentNode<{ listInitiatives: AdminInitiative[] }, { status?: string | null; search?: string | null; first?: number; after?: string }> = gql`
 query ListInitiatives($status: String, $search: String, $first: Int, $after: String) {
   listInitiatives(status: $status, search: $search, first: $first, after: $after) { id name slug hashtag description status windowStartsAt windowEndsAt rules { id initiativeId key valueJson locked } }
 }
`;

export const GET_INITIATIVE: TypedDocumentNode<{ getInitiative: AdminInitiative | null }, { id: string }> = gql`
 query GetInitiative($id: ID!) {
   getInitiative(id: $id) {
     id name slug hashtag description status windowStartsAt windowEndsAt
     rules { id initiativeId key valueJson locked }
     mountedEvents {
       id initiativeId slug title status startsAt registrationDeadline venue
       workspaceId workspaceName confirmedCount pricingEnabled depositEnabled
       depositAmountCents minAge minParticipants
     }
   }
 }
`;

export type AdminInitiativePayload = { result: AdminInitiative | null; errors: MutationError[] };
export const CREATE_INITIATIVE = gql`mutation CreateInitiative($input: AdminInitiativeInput!) { createInitiative(input: $input) { result { id name slug status } errors { code message } } }`;
export const UPDATE_INITIATIVE = gql`mutation UpdateInitiative($id: ID!, $input: AdminInitiativeInput!) { updateInitiative(id: $id, input: $input) { result { id name slug status } errors { code message } } }`;
export const OPEN_INITIATIVE = gql`mutation OpenInitiative($id: ID!) { openInitiative(id: $id) { result { id name slug status } errors { code message } } }`;
export const CLOSE_INITIATIVE = gql`mutation CloseInitiative($id: ID!) { closeInitiative(id: $id) { result { id name slug status } errors { code message } } }`;
export const CANCEL_INITIATIVE = gql`mutation CancelInitiative($id: ID!) { cancelInitiative(id: $id) { result { id name slug status } errors { code message } } }`;
/** #595：errors 取 fields，规则被拒时前端可定位到具体场/工作台 */
export const UPSERT_INITIATIVE_RULE = gql`mutation UpsertInitiativeRule($initiativeId: ID!, $key: String!, $valueJson: String!, $locked: Boolean!) { upsertInitiativeRule(initiativeId: $initiativeId, key: $key, valueJson: $valueJson, locked: $locked) { result { id initiativeId key valueJson locked } errors { code message fields } } }`;

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
	/** 枚举值：workspace_create | application_approve | application_reject | admin_promote | admin_demote | owner_reassign | owner_invitation_cancel | initiative_rule_update | ... */
	action: string;
	/** 目标类型：workspace | workspace_application | user | initiative | ... */
	targetType: string;
	targetId: string;
	/** v1 恒为 "success" */
	result: string;
	insertedAt: string;
	/** #607 治理 metadata 白名单投影；未收录的 action、或形状不完整的历史行（#587 之前）= null */
	metadata: AdminActionMetadata | null;
}

/**
 * #607 治理 metadata 白名单投影（**不是**原始 metadata 列）。
 *
 * `valueBeforeJson` / `valueAfterJson` 是 JSON 对象字符串，键序 = 后端二级白名单
 * （`Cgc2046Web.GraphqlSchema` 顶部 `@rule_value_whitelist`）→ 前端 `JSON.parse`
 * 后按序渲染即可，不再抄一份键名清单。
 * `value*Omitted` = 该侧原始 value map 含白名单外键（或值不是标量）被省略
 * （必须显式告知，不静默截断）。
 *
 * 后端**形状门**保证：`metadata` 非 null ⇒ `valueAfterJson` 非 null（形状不全的历史行
 * 整行返回 null，不算「新建」）⇒ 只有 `valueBeforeJson === null` 才意味着新建规则。
 */
export interface AdminActionMetadata {
	ruleKey: string;
	locked: boolean;
	/** null ⇔ 新建规则（:create 无前值） */
	lockedBefore: boolean | null;
	/** null ⇔ 新建规则 */
	valueBeforeJson: string | null;
	valueAfterJson: string;
	valueBeforeOmitted: boolean;
	valueAfterOmitted: boolean;
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
      metadata {
        ruleKey
        locked
        lockedBefore
        valueBeforeJson
        valueAfterJson
        valueBeforeOmitted
        valueAfterOmitted
      }
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

/* Initiative 状态徽章：后端 status 为 string，未知状态由调用侧 `?? l-badge-muted` 兜底。 */
export const INITIATIVE_STATUS_CLASS: Record<string, string> = {
	draft: "l-badge l-badge-muted",
	open: "l-badge l-badge-success",
	closed: "l-badge l-badge-muted",
	cancelled: "l-badge l-badge-danger",
};

/* ---------------- 闪念间看板（U11/R24/R25） ---------------- */

/** 四率（KTD10）：分子=touch distinct person；分母=成功送达（硬退信与退订剔除） */
export interface FlashbackRates {
	delivered: number;
	linkOpened: number;
	revealed: number;
	sentToWall: number;
	intentSubmitted: number;
}

export interface FlashbackAdminStats {
	memory: FlashbackRates;
	dream: FlashbackRates;
	overall: FlashbackRates;
}

export interface FlashbackRedemption {
	id: string;
	status: string;
	/** 用户提交的收款渠道（admin-only，KTD3——不进任何导出） */
	channelNote: string;
	handledNote?: string | null;
	insertedAt?: string | null;
	maskedName?: string | null;
	city?: string | null;
}

export const FLASHBACK_ADMIN_STATS: TypedDocumentNode<
	{ flashbackAdminStats: FlashbackAdminStats },
	Record<string, never>
> = gql`
	query FlashbackAdminStats {
		flashbackAdminStats {
			memory {
				delivered
				linkOpened
				revealed
				sentToWall
				intentSubmitted
			}
			dream {
				delivered
				linkOpened
				revealed
				sentToWall
				intentSubmitted
			}
			overall {
				delivered
				linkOpened
				revealed
				sentToWall
				intentSubmitted
			}
		}
	}
`;

export const FLASHBACK_ADMIN_REDEMPTIONS: TypedDocumentNode<
	{ flashbackAdminRedemptions: FlashbackRedemption[] },
	{ limit?: number | null }
> = gql`
	query FlashbackAdminRedemptions($limit: Int) {
		flashbackAdminRedemptions(limit: $limit) {
			id
			status
			channelNote
			handledNote
			insertedAt
			maskedName
			city
		}
	}
`;

export const FLASHBACK_ADMIN_UPDATE_REDEMPTION: TypedDocumentNode<
	{ flashbackAdminUpdateRedemption: { id: string; status: string } },
	{ id: string; status: string; handledNote?: string | null }
> = gql`
	mutation FlashbackAdminUpdateRedemption($id: ID!, $status: String!, $handledNote: String) {
		flashbackAdminUpdateRedemption(id: $id, status: $status, handledNote: $handledNote) {
			id
			status
		}
	}
`;
