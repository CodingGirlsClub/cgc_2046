import { client } from "./apollo-client";
import type { AuditFilters } from "./admin";
import {
	PLATFORM_WORKFLOW_AUDIT,
	type WorkflowRun,
	type WorkflowRunStatus,
} from "./graphql/workflow";

/**
 * Platform Admin 脱敏 workflow audit 数据源。Workspace 成员不再通过此 adapter
 * 读取 raw WorkflowRun；学习状态走 myLearningRuns。
 */

export interface WorkflowRunItem {
	id: string;
	status: WorkflowRunStatus;
	workspaceId?: string;
	definitionType: string;
	startedAt: string | null;
	finishedAt: string | null;
	insertedAt?: string;
	errorSummary?: string | null;
}

/** #23：请求超时 signal（15s）。超时后 abort，Apollo 报 AbortError → 调用方错误态。 */
const REQUEST_TIMEOUT_MS = 15_000;

function timeoutSignal(): AbortSignal {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
	// 请求完成时清理定时器（signal 不保留引用，GC 回收时定时器随之清除）
	controller.signal.addEventListener(
		"abort",
		() => clearTimeout(timer),
		{ once: true },
	);
	return controller.signal;
}

/**
 * 获取脱敏 audit 列表，仅 admin audit 页免 workspace scope 使用。
 * filter 用 eq 内层包装；read policy 经 workspace → memberships 路径，
 * 成员可见本工作台 run，非成员空结果（无需额外 query 内 filter）。
 * #117：filters.status → status.eq；filters.insertedAfter/Before → startedAt 比较器
 * （自动 filter 无 insertedAt；startedAt 与 audit 页时间列一致）。
 */
export async function fetchWorkflowRuns(
	workspaceId?: string,
	opts?: { first?: number; after?: string; filters?: AuditFilters },
): Promise<WorkflowRunItem[]> {
	const variables = { workspaceId, status: opts?.filters?.status, startedAfter: opts?.filters?.insertedAfter, startedBefore: opts?.filters?.insertedBefore };

	const result = await client.query({
		query: PLATFORM_WORKFLOW_AUDIT,
		variables,
		// #23：请求超时——GraphQL 端点挂起时中止请求，让页面落到错误态而非无限 loading。
		// Apollo 经 context.fetchOptions 把 signal 透传给 fetch（createHttpLink）。
		context: { fetchOptions: { signal: timeoutSignal() } },
	});
	const data = result?.data;

	return Array.isArray(data?.platformWorkflowAudit)
		? data.platformWorkflowAudit.map((r) => ({
				id: r.id,
				status: r.status,
				workspaceId: r.workspaceId,
				definitionType: r.definitionType,
				startedAt: r.startedAt,
				finishedAt: r.finishedAt,
				insertedAt: r.insertedAt,
				errorSummary: r.errorSummary,
			}))
		: [];
}
