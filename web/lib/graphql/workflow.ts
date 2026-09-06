import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * Platform Admin 脱敏 WorkflowRun 审计查询。
 * 原始 listWorkflowRuns/getWorkflowRun GraphQL 面已移除，业务页面不得读取 raw facts。
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

/** WorkflowRun（后端 type WorkflowRun 实测字段） */
export interface WorkflowRun {
	id: string;
	workspaceId: string;
	definitionId: string;
	definitionVersion: number;
	status: WorkflowRunStatus;
	/** JsonString：JSON 编码字符串，数据层 JSON.parse 后使用 */
	inputSnapshot: string | null;
	/** JsonString：JSON 编码字符串，数据层 JSON.parse 后使用 */
	facts: string | null;
	partitionId: string | null;
	version: number;
	startedAt: string | null;
	finishedAt: string | null;
	/** plan 020 U3：run 绑定版本的 definition（版本快照，非最新定义） */
	definition: { type: string } | null;
	definitionType?: string | null;
	/** plan 020 U3：JsonString 数组——每项 JSON 编码步骤摘要 {step_key,title,type,output_schema} */
	steps: string[] | null;
}

/** listWorkflowRuns 分页对象（KeysetPageOfWorkflowRun 实测形态） */
export interface WorkflowRunConnection {
	/** SDL 为 nullable `count: Int`（schema.graphql:19）— 与 SDL 对齐 */
	count: number | null;
	results: WorkflowRun[];
	startKeyset?: string | null;
	endKeyset?: string | null;
}

/** listWorkflowRuns filter：比较器内层包装（同 WorkspaceMembersFilter 模式） */
export interface WorkflowRunFilter {
	workspaceId?: { eq?: string } | null;
	status?: { eq?: string } | null;
	/** #117：audit 页时间范围映射到 startedAt（自动 filter 无 insertedAt） */
	startedAt?: {
		greaterThanOrEqual?: string;
		lessThanOrEqual?: string;
	} | null;
}

/* ---------------- redacted audit query ---------------- */

/**
 * #40 listWorkflowRuns：工作台 run 列表（分页对象，filter 用 eq 包装 workspaceId）。
 * 只读展示页消费；run 创建/状态流转不经 GraphQL 暴露（ResearchInstantiator 内部调用）。
 */
export const PLATFORM_WORKFLOW_AUDIT: TypedDocumentNode<
	{ platformWorkflowAudit: WorkflowRun[] },
	{ workspaceId?: string; status?: string }
> = gql`
	query PlatformWorkflowAudit($workspaceId: ID, $status: String) {
		platformWorkflowAudit(workspaceId: $workspaceId, status: $status) {
				id
				workspaceId
				definitionType
				status
				startedAt
				finishedAt
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
