import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationError, MutationResult } from "./shared";
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
	/** U1 offering 治理写变更投影；未收录的 action（launch/close/cancel 等）或闭集列零变更 = null */
	offeringChange: AdminOfferingChangeMetadata | null;
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

/**
 * U1 offering 治理写变更投影（`adminActionLog.offeringChange`，**非** rule 族 metadata）。
 *
 * 闭集标量前后值分列：标题 / visibility / capacity / pricingEnabled / depositEnabled。
 * 写面只为**真变更**的属性落键 → 该列两侧同为 null = 本次未改该属性（不是「改成空」）；
 * `depositEnabled*` 对 Course 恒 null（该资源无押金槽位）。自由文本（描述/场地）不在此面。
 */
export interface AdminOfferingChangeMetadata {
	titleBefore: string | null;
	titleAfter: string | null;
	visibilityBefore: string | null;
	visibilityAfter: string | null;
	capacityBefore: number | null;
	capacityAfter: number | null;
	pricingEnabledBefore: boolean | null;
	pricingEnabledAfter: boolean | null;
	depositEnabledBefore: boolean | null;
	depositEnabledAfter: boolean | null;
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
      offeringChange {
        titleBefore
        titleAfter
        visibilityBefore
        visibilityAfter
        capacityBefore
        capacityAfter
        pricingEnabledBefore
        pricingEnabledAfter
        depositEnabledBefore
        depositEnabledAfter
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
		/** KTD5：必须与 entityType 成对下发（单独下发后端 `invalid_input` 拒绝） */
		entityId?: string | null;
		workspaceId?: string | null;
		first?: number;
		after?: string;
	} & AdminListArgs
> = gql`
  query ReconciliationFindings(
    $rule: String
    $entityType: String
    $entityId: String
    $workspaceId: ID
    $first: Int
    $after: String
  ) {
    reconciliationFindings(
      rule: $rule
      entityType: $entityType
      entityId: $entityId
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
	payment_amount_mismatch: "labels.reconRule.payment_amount_mismatch",
	payment_recon: "labels.reconRule.payment_recon",
	open_offering_without_ledger: "labels.reconRule.open_offering_without_ledger",
	ledger_occupancy_mismatch: "labels.reconRule.ledger_occupancy_mismatch",
	capacity_projection_drift: "labels.reconRule.capacity_projection_drift",
	occupancy_exceeds_capacity: "labels.reconRule.occupancy_exceeds_capacity",
	ledger_cache_drift: "labels.reconRule.ledger_cache_drift",
	fund_action_burst: "labels.reconRule.fund_action_burst",
	deposit_settlement_unanchored: "labels.reconRule.deposit_settlement_unanchored",
	notification_delivery_failed: "labels.reconRule.notification_delivery_failed",
	deposit_forfeit_batch_alert: "labels.reconRule.deposit_forfeit_batch_alert",
	refunding_without_refund_job: "labels.reconRule.refunding_without_refund_job",
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

/* -------- U3 治理面：Event 读投影与生命周期/元数据写（对齐 SDL AdminEvent/AdminEventDetail） -------- */

/**
 * 平台管理员跨租户 Event 行投影（`listAdminEvents`；含 draft 与终态行，
 * 不受公开可见性过滤）。
 *
 * 列表刻意不带报名计数：KTD4 的权威计数只在 `getAdminEvent` 详情现取——
 * 展示投影列（events.confirmed_count）可能滞后一拍，不做治理判据。
 */
export interface AdminEvent {
	id: string;
	workspaceId: string;
	title: string;
	slug?: string | null;
	/** draft | open | closed | cancelled */
	status: string;
	visibility: string;
	/** nil = 不限名额 */
	capacity?: number | null;
	registrationDeadline?: string | null;
	startsAt?: string | null;
	endsAt?: string | null;
	pricingEnabled: boolean;
	depositEnabled: boolean;
	depositAmountCents?: number | null;
	insertedAt: string;
	updatedAt: string;
}

/** 主理人（`getAdminEvent.moderators` 元素） */
export interface AdminEventModerator {
	id: string;
	userId: string;
}

/**
 * Event 治理详情（`getAdminEvent`；id 不存在返回 null，不是 GraphQL 错误）。
 *
 * 计数语义（KTD4，与 SDL 注释逐字对齐）：`null` = **计数不可用**（现取失败），
 * 界面必须按不可用态呈现并禁用依赖它的入口，不得当 0；`0` 才是真实无报名。
 * 同理 `moderators`：`null` = 清单加载失败，`[]` = 真的无主理人。
 */
export interface AdminEventDetail extends AdminEvent {
	description?: string | null;
	/** 结构化场地 JSON 串（JsonString；nil = 线上/未定） */
	venue?: string | null;
	confirmedCount?: number | null;
	paymentPendingCount?: number | null;
	moderators?: AdminEventModerator[] | null;
	/** 解除挂载来源标记 JSON 串；nil = 无标记 */
	detachedRuleProvenance?: string | null;
}

/** 治理 update 输入：只落**本次真变更**的键（未传 = 不改；显式 null = 清空该列）。 */
export interface AdminEventUpdateInput {
	title?: string;
	visibility?: string;
	capacity?: number | null;
	registrationDeadline?: string | null;
	startsAt?: string | null;
	endsAt?: string | null;
	venue?: string | null;
	pricingEnabled?: boolean;
	depositEnabled?: boolean;
}

export const LIST_ADMIN_EVENTS: TypedDocumentNode<
	{ listAdminEvents: AdminEvent[] },
	{
		status?: string | null;
		search?: string | null;
		workspaceId?: string | null;
		first?: number;
		after?: string;
	} & AdminListArgs
> = gql`
  query ListAdminEvents(
    $status: String
    $search: String
    $workspaceId: ID
    $first: Int
    $after: String
  ) {
    listAdminEvents(
      status: $status
      search: $search
      workspaceId: $workspaceId
      first: $first
      after: $after
    ) {
      id
      workspaceId
      title
      slug
      status
      visibility
      capacity
      registrationDeadline
      startsAt
      endsAt
      pricingEnabled
      depositEnabled
      depositAmountCents
      insertedAt
      updatedAt
    }
  }
`;

export const GET_ADMIN_EVENT: TypedDocumentNode<
	{ getAdminEvent: AdminEventDetail | null },
	{ id: string }
> = gql`
  query GetAdminEvent($id: ID!) {
    getAdminEvent(id: $id) {
      id
      workspaceId
      title
      slug
      description
      status
      visibility
      capacity
      registrationDeadline
      startsAt
      endsAt
      venue
      pricingEnabled
      depositEnabled
      depositAmountCents
      confirmedCount
      paymentPendingCount
      moderators {
        id
        userId
      }
      detachedRuleProvenance
      insertedAt
      updatedAt
    }
  }
`;

/** 治理写结果的行子集（状态切换/元数据写都不需要整行回读——刷新走 get 现取） */
export type AdminEventMutationResult = {
	id: string;
	slug?: string | null;
	status: string;
};

export type AdminEventPayload = MutationResult<AdminEventMutationResult>;

/** 状态迁移：draft → open / open → closed / open → cancelled（后端状态机复验） */
export const ADMIN_LAUNCH_EVENT = gql`mutation AdminLaunchEvent($id: ID!) { adminLaunchEvent(id: $id) { result { id slug status } errors { code message fields } } }`;
export const ADMIN_CLOSE_EVENT = gql`mutation AdminCloseEvent($id: ID!) { adminCloseEvent(id: $id) { result { id slug status } errors { code message fields } } }`;
export const ADMIN_CANCEL_EVENT = gql`mutation AdminCancelEvent($id: ID!) { adminCancelEvent(id: $id) { result { id slug status } errors { code message fields } } }`;
export const ADMIN_UPDATE_EVENT = gql`mutation AdminUpdateEvent($id: ID!, $input: AdminEventUpdateInput!) { adminUpdateEvent(id: $id, input: $input) { result { id slug status } errors { code message fields } } }`;

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

// ── 闪念间触达运营台（R4/R7-R10）──────────────────────────────────────────

export interface FlashbackOutreachPreview {
	archiveKey: string;
	archiveName: string;
	channel: string;
	queued: number;
	emailOnly: number;
	smsOnly: number;
	both: number;
	unsubscribed: number;
	unreachable: number;
	smsReady: boolean;
}

// ── wish2 愿望管理（U5/KTD5）────────────────────────────────────────────────

export interface FlashbackAdminWishInboxEntry {
	wishId: string;
	content: string;
	city?: string | null;
	signature: string;
	insertedAt: string;
	wisherMasked?: string | null;
	/** 仅 platform admin；联系方式仅用于主办方对接出力事宜，不对外公开 */
	wisherPhone?: string | null;
	wisherEmail?: string | null;
}

export interface FlashbackAdminReportEntry {
	reportId: string;
	targetType: string;
	targetId: string;
	reasonType: string;
	reasonFree?: string | null;
	status: string;
	insertedAt: string;
}

export const FLASHBACK_ADMIN_WISH_INBOX: TypedDocumentNode<
	{ flashbackAdminWishInbox: FlashbackAdminWishInboxEntry[] },
	Record<string, never>
> = gql`
	query FlashbackAdminWishInbox {
		flashbackAdminWishInbox {
			wishId
			content
			city
			signature
			insertedAt
			wisherMasked
			wisherPhone
			wisherEmail
		}
	}
`;

export const FLASHBACK_ADMIN_WISH_REPORTS: TypedDocumentNode<
	{ flashbackAdminWishReports: FlashbackAdminReportEntry[] },
	Record<string, never>
> = gql`
	query FlashbackAdminWishReports {
		flashbackAdminWishReports {
			reportId
			targetType
			targetId
			reasonType
			reasonFree
			status
			insertedAt
		}
	}
`;

export const FLASHBACK_ADMIN_DISMISS_REPORT: TypedDocumentNode<
	{ flashbackAdminDismissReport: { reportId: string; status: string } | null },
	{ reportId: string }
> = gql`
	mutation FlashbackAdminDismissReport($reportId: ID!) {
		flashbackAdminDismissReport(reportId: $reportId) {
			reportId
			status
		}
	}
`;

export const FLASHBACK_ADMIN_APPROVE_REPORT: TypedDocumentNode<
	{ flashbackAdminApproveReport: { reportId: string; status: string } | null },
	{ reportId: string }
> = gql`
	mutation FlashbackAdminApproveReport($reportId: ID!) {
		flashbackAdminApproveReport(reportId: $reportId) {
			reportId
			status
		}
	}
`;

export const FLASHBACK_ADMIN_SET_WISH_HIDDEN: TypedDocumentNode<
	{ flashbackAdminSetWishHidden: { wishId: string; hidden: boolean } | null },
	{ wishId: string; hidden: boolean }
> = gql`
	mutation FlashbackAdminSetWishHidden($wishId: ID!, $hidden: Boolean!) {
		flashbackAdminSetWishHidden(wishId: $wishId, hidden: $hidden) {
			wishId
			hidden
		}
	}
`;

export type FlashbackAdminWishEchoStatus = "draft" | "published" | "corrected" | "revoked";

export interface FlashbackAdminWishEcho {
	id: string;
	content: string;
	status: FlashbackAdminWishEchoStatus;
	insertedAt: string;
	publishedAt?: string | null;
	correctedAt?: string | null;
	revokedAt?: string | null;
}

export interface FlashbackAdminWishEchoesResult {
	echoes: FlashbackAdminWishEcho[];
	currentNotifiableEndorsementCount: number;
}

export interface FlashbackAdminListedWishEntry {
	wishId: string;
	content: string;
	signature?: string | null;
	city?: string | null;
	listedAt: string;
	publishedEchoCount: number;
	draftEchoCount: number;
}

export const FLASHBACK_ADMIN_LISTED_WISHES: TypedDocumentNode<
	{ flashbackAdminListedWishes: FlashbackAdminListedWishEntry[] },
	Record<string, never>
> = gql`
	query FlashbackAdminListedWishes {
		flashbackAdminListedWishes {
			wishId
			content
			signature
			city
			listedAt
			publishedEchoCount
			draftEchoCount
		}
	}
`;

export const FLASHBACK_ADMIN_WISH_ECHOES: TypedDocumentNode<
	{ flashbackAdminWishEchoes: FlashbackAdminWishEchoesResult | null },
	{ wishId: string }
> = gql`
	query FlashbackAdminWishEchoes($wishId: ID!) {
		flashbackAdminWishEchoes(wishId: $wishId) {
			echoes {
				id
				content
				status
				insertedAt
				publishedAt
				correctedAt
				revokedAt
			}
			currentNotifiableEndorsementCount
		}
	}
`;

export const FLASHBACK_ADMIN_CREATE_WISH_ECHO: TypedDocumentNode<
	{ flashbackAdminCreateWishEcho: FlashbackAdminWishEcho | null },
	{ wishId: string; content: string }
> = gql`
	mutation FlashbackAdminCreateWishEcho($wishId: ID!, $content: String!) {
		flashbackAdminCreateWishEcho(wishId: $wishId, content: $content) {
			id
			content
			status
			insertedAt
		}
	}
`;

export const FLASHBACK_ADMIN_UPDATE_WISH_ECHO_DRAFT: TypedDocumentNode<
	{ flashbackAdminUpdateWishEchoDraft: FlashbackAdminWishEcho | null },
	{ echoId: string; content: string }
> = gql`
	mutation FlashbackAdminUpdateWishEchoDraft($echoId: ID!, $content: String!) {
		flashbackAdminUpdateWishEchoDraft(echoId: $echoId, content: $content) {
			id
			content
			status
		}
	}
`;

export const FLASHBACK_ADMIN_PUBLISH_WISH_ECHO: TypedDocumentNode<
	{ flashbackAdminPublishWishEcho: FlashbackAdminWishEcho | null },
	{ echoId: string }
> = gql`
	mutation FlashbackAdminPublishWishEcho($echoId: ID!) {
		flashbackAdminPublishWishEcho(echoId: $echoId) {
			id
			status
			publishedAt
		}
	}
`;

export const FLASHBACK_ADMIN_CORRECT_WISH_ECHO: TypedDocumentNode<
	{ flashbackAdminCorrectWishEcho: FlashbackAdminWishEcho | null },
	{ echoId: string; content: string }
> = gql`
	mutation FlashbackAdminCorrectWishEcho($echoId: ID!, $content: String!) {
		flashbackAdminCorrectWishEcho(echoId: $echoId, content: $content) {
			id
			status
			content
			correctedAt
		}
	}
`;

export const FLASHBACK_ADMIN_REVOKE_WISH_ECHO: TypedDocumentNode<
	{ flashbackAdminRevokeWishEcho: FlashbackAdminWishEcho | null },
	{ echoId: string }
> = gql`
	mutation FlashbackAdminRevokeWishEcho($echoId: ID!) {
		flashbackAdminRevokeWishEcho(echoId: $echoId) {
			id
			status
			revokedAt
		}
	}
`;

export interface FlashbackOutreachBatchChannel {
	queued: number;
	sent: number;
	failed: number;
}

export interface FlashbackOutreachBatch {
	batch: string;
	template: string;
	firstAt?: string | null;
	email: FlashbackOutreachBatchChannel;
	sms: FlashbackOutreachBatchChannel;
}

export interface FlashbackOutreachLast {
	channel: string;
	status: string;
	batch: string;
	at?: string | null;
}

export interface FlashbackOutreachRosterEntry {
	personId: string;
	fullName: string;
	email?: string | null;
	phone?: string | null;
	claimed: boolean;
	participation: string;
	unsubscribed: boolean;
	deleted: boolean;
	emailReachable: boolean;
	smsReachable: boolean;
	lastOutreach?: FlashbackOutreachLast | null;
}

export interface FlashbackAdminArchive {
	key: string;
	name: string;
	// 教练场等档案无具体日期/城市（backend schema 为 nullable）
	city: string | null;
	occurredOn: string | null;
}

export const FLASHBACK_OUTREACH_PREVIEW: TypedDocumentNode<
	{ flashbackOutreachPreview: FlashbackOutreachPreview },
	{ archiveKey: string; channel?: string | null }
> = gql`
	query FlashbackOutreachPreview($archiveKey: String!, $channel: String) {
		flashbackOutreachPreview(archiveKey: $archiveKey, channel: $channel) {
			archiveKey
			archiveName
			channel
			queued
			emailOnly
			smsOnly
			both
			unsubscribed
			unreachable
			smsReady
		}
	}
`;

export const FLASHBACK_OUTREACH_BATCHES: TypedDocumentNode<
	{ flashbackOutreachBatches: FlashbackOutreachBatch[] },
	{ archiveKey: string }
> = gql`
	query FlashbackOutreachBatches($archiveKey: String!) {
		flashbackOutreachBatches(archiveKey: $archiveKey) {
			batch
			template
			firstAt
			email {
				queued
				sent
				failed
			}
			sms {
				queued
				sent
				failed
			}
		}
	}
`;

export const FLASHBACK_OUTREACH_ROSTER: TypedDocumentNode<
	{ flashbackOutreachRoster: FlashbackOutreachRosterEntry[] },
	{ archiveKey: string; filter?: string | null; search?: string | null }
> = gql`
	query FlashbackOutreachRoster($archiveKey: String!, $filter: String, $search: String) {
		flashbackOutreachRoster(archiveKey: $archiveKey, filter: $filter, search: $search) {
			personId
			fullName
			email
			phone
			claimed
			participation
			unsubscribed
			deleted
			emailReachable
			smsReachable
			lastOutreach {
				channel
				status
				batch
				at
			}
		}
	}
`;

export const FLASHBACK_ADMIN_ARCHIVES: TypedDocumentNode<
	{ flashbackAdminArchives: FlashbackAdminArchive[] },
	Record<string, never>
> = gql`
	query FlashbackAdminArchives {
		flashbackAdminArchives {
			key
			name
			city
			occurredOn
		}
	}
`;

export const FLASHBACK_ADMIN_SEND_OUTREACH: TypedDocumentNode<
	{ flashbackAdminSendOutreach: { queued: number; skipped: number } },
	{ archiveKey: string; template: string; channel?: string | null }
> = gql`
	mutation FlashbackAdminSendOutreach($archiveKey: String!, $template: String!, $channel: String) {
		flashbackAdminSendOutreach(
			archiveKey: $archiveKey
			template: $template
			channel: $channel
		) {
			queued
			skipped
		}
	}
`;

export const FLASHBACK_ADMIN_RESEND_OUTREACH: TypedDocumentNode<
	{ flashbackAdminResendOutreach: { queued: number; skipped: number } },
	{ personId: string; template: string; channel?: string | null }
> = gql`
	mutation FlashbackAdminResendOutreach($personId: ID!, $template: String!, $channel: String) {
		flashbackAdminResendOutreach(
			personId: $personId
			template: $template
			channel: $channel
		) {
			queued
			skipped
		}
	}
`;

/** Offering（Event/Course）状态徽章：与 `INITIATIVE_STATUS_CLASS` 同映射，未知状态同样由调用侧兜底。 */
export const OFFERING_STATUS_CLASS: Record<string, string> = {
	draft: "l-badge l-badge-muted",
	open: "l-badge l-badge-success",
	closed: "l-badge l-badge-muted",
	cancelled: "l-badge l-badge-danger",
};

/**
 * 状态下拉枚举（后端 `Event.status_values/0` 单源镜像）：只给合法值，
 * 规避后端 `maybe_status_filter` 对非法值静默回退的误判面（plan Assumptions）。
 */
export const OFFERING_STATUS_VALUES = [
	"draft",
	"open",
	"closed",
	"cancelled",
] as const;

/** 可见性枚举（后端 `@visibility_values` 单源镜像；标签取 `labels.visibility.*`） */
export const OFFERING_VISIBILITY_VALUES = ["public", "workspace"] as const;

/* -------- U4 治理面：Course 读投影与生命周期/元数据写（对齐 SDL AdminCourse/AdminCourseDetail） -------- */

/**
 * 平台管理员跨租户 Course 行投影（`listAdminCourses`；含 draft 与终态行，
 * 不受公开可见性过滤）。
 *
 * 列表刻意不带报名计数：KTD4 的权威计数只在 `getAdminCourse` 详情现取——
 * 展示投影列（courses.confirmed_count）可能滞后一拍，不做治理判据。
 *
 * Course 无 `depositEnabled` / `depositAmountCents`（押金为 Event-only 槽位），
 * 也无 venue / 主理人 / 挂载来源标记——投影差异照 SDL，不补齐 Event 形状。
 */
export interface AdminCourse {
	id: string;
	workspaceId: string;
	title: string;
	/** 标题是否为系统生成的临时占位（未命名课程）；发布前置门，列表据此标黄 */
	provisionalTitle: boolean;
	slug?: string | null;
	/** draft | open | closed | cancelled */
	status: string;
	visibility: string;
	/** nil = 不限名额 */
	capacity?: number | null;
	registrationDeadline?: string | null;
	startsAt?: string | null;
	endsAt?: string | null;
	pricingEnabled: boolean;
	insertedAt: string;
	updatedAt: string;
}

/**
 * Course 治理详情（`getAdminCourse`；id 不存在返回 null，不是 GraphQL 错误）。
 *
 * 计数语义（KTD4，与 SDL 注释逐字对齐）：`null` = **计数不可用**（现取失败），
 * 界面必须按不可用态呈现并禁用依赖它的入口，不得当 0；`0` 才是真实无报名。
 */
export interface AdminCourseDetail extends AdminCourse {
	description?: string | null;
	/** 当前绑定修订号（current_revision_id 现取）；null = 未绑定（draft 未发布常态）或现取失败 */
	currentRevisionNumber?: number | null;
	confirmedCount?: number | null;
	paymentPendingCount?: number | null;
}

/** 治理 update 输入：只落**本次真变更**的键（未传 = 不改；显式 null = 清空该列）。 */
export interface AdminCourseUpdateInput {
	title?: string;
	description?: string | null;
	visibility?: string;
	capacity?: number | null;
	registrationDeadline?: string | null;
	startsAt?: string | null;
	endsAt?: string | null;
	pricingEnabled?: boolean;
}

export const LIST_ADMIN_COURSES: TypedDocumentNode<
	{ listAdminCourses: AdminCourse[] },
	{
		status?: string | null;
		search?: string | null;
		workspaceId?: string | null;
		first?: number;
		after?: string;
	} & AdminListArgs
> = gql`
  query ListAdminCourses(
    $status: String
    $search: String
    $workspaceId: ID
    $first: Int
    $after: String
  ) {
    listAdminCourses(
      status: $status
      search: $search
      workspaceId: $workspaceId
      first: $first
      after: $after
    ) {
      id
      workspaceId
      title
      provisionalTitle
      slug
      status
      visibility
      capacity
      registrationDeadline
      startsAt
      endsAt
      pricingEnabled
      insertedAt
      updatedAt
    }
  }
`;

export const GET_ADMIN_COURSE: TypedDocumentNode<
	{ getAdminCourse: AdminCourseDetail | null },
	{ id: string }
> = gql`
  query GetAdminCourse($id: ID!) {
    getAdminCourse(id: $id) {
      id
      workspaceId
      title
      provisionalTitle
      slug
      description
      status
      visibility
      capacity
      registrationDeadline
      startsAt
      endsAt
      pricingEnabled
      currentRevisionNumber
      confirmedCount
      paymentPendingCount
      insertedAt
      updatedAt
    }
  }
`;

/** 治理写结果的行子集（状态切换/元数据写都不需要整行回读——刷新走 get 现取） */
export type AdminCourseMutationResult = {
	id: string;
	slug?: string | null;
	status: string;
};

export type AdminCoursePayload = MutationResult<AdminCourseMutationResult>;

/** 状态迁移：draft → open / open → closed / open → cancelled（后端状态机复验） */
export const ADMIN_LAUNCH_COURSE = gql`mutation AdminLaunchCourse($id: ID!) { adminLaunchCourse(id: $id) { result { id slug status } errors { code message fields } } }`;
export const ADMIN_CLOSE_COURSE = gql`mutation AdminCloseCourse($id: ID!) { adminCloseCourse(id: $id) { result { id slug status } errors { code message fields } } }`;
export const ADMIN_CANCEL_COURSE = gql`mutation AdminCancelCourse($id: ID!) { adminCancelCourse(id: $id) { result { id slug status } errors { code message fields } } }`;
export const ADMIN_UPDATE_COURSE = gql`mutation AdminUpdateCourse($id: ID!, $input: AdminCourseUpdateInput!) { adminUpdateCourse(id: $id, input: $input) { result { id slug status } errors { code message fields } } }`;
