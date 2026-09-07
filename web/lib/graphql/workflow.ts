import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * Platform Admin 脱敏 WorkflowRun 审计查询。
 * 平台审计 GraphQL 面只返回脱敏运行元数据，业务页面不得读取 raw facts。
 */

/* ---------------- 类型（对齐 backend/priv/graphql/schema.graphql） ---------------- */

/**
 * WorkflowRun status（后端 @status_values 状态机，GraphQL 侧为 String!）。
 * 展示页按此 union 渲染中文 label。
 */
export type WorkflowRunStatus =
	| "pending"
	| "running"
	| "waiting"
	| "succeeded"
	| "failed"
	| "cancelled"
	| "expired";

/** Platform audit 行：刻意脱敏；facts/输入快照不在该形状内。 */
export interface WorkflowRun {
	id: string;
	workspaceId: string;
	definitionType: string;
	status: WorkflowRunStatus;
	startedAt: string | null;
	finishedAt: string | null;
	insertedAt: string;
	errorSummary?: string | null;
}

/** Filter shape used by the operational audit adapter. */
export interface WorkflowRunFilter {
	workspaceId?: { eq?: string } | null;
	status?: { eq?: string } | null;
	/** Audit time range is applied to the redacted startedAt column. */
	startedAt?: {
		greaterThanOrEqual?: string;
		lessThanOrEqual?: string;
	} | null;
}

/* ---------------- redacted audit query ---------------- */

/** Platform Admin operational audit query; the response contains metadata only. */
export const PLATFORM_WORKFLOW_AUDIT: TypedDocumentNode<
	{ platformWorkflowAudit: WorkflowRun[] },
	{ workspaceId?: string; status?: string; startedAfter?: string; startedBefore?: string }
> = gql`
	query PlatformWorkflowAudit($workspaceId: ID, $status: String, $startedAfter: DateTime, $startedBefore: DateTime) {
		platformWorkflowAudit(workspaceId: $workspaceId, status: $status, startedAfter: $startedAfter, startedBefore: $startedBefore) {
				id
				workspaceId
				definitionType
				status
				startedAt
				finishedAt
				insertedAt
				errorSummary
			}
	}
`;

/* ---------------- status 展示辅助 ---------------- */

/** WorkflowRun status 中文 label（对齐后端 @status_values 七态） */
export const WORKFLOW_RUN_STATUS_LABEL: Record<WorkflowRunStatus, string> = {
	pending: "labels.workflowStatus.pending",
	running: "labels.workflowStatus.running",
	waiting: "labels.workflowStatus.waiting",
	succeeded: "labels.workflowStatus.succeeded",
	failed: "labels.workflowStatus.failed",
	cancelled: "labels.workflowStatus.cancelled",
	expired: "labels.workflowStatus.expired",
};
