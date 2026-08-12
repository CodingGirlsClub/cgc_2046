import { client } from "./apollo-client";
import type { AuditFilters } from "./admin";
import {
	LIST_WORKFLOW_RUNS,
	type WorkflowRun,
	type WorkflowRunConnection,
	type WorkflowRunFilter,
	type WorkflowRunStatus,
} from "./graphql/workflow";

/**
 * #40 教研产出数据源。
 *
 * 唯一真实路径 = GraphQL listWorkflowRuns（filter 用 { workspaceId: { eq } } 内层包装）。
 * 后端 facts/inputSnapshot 是 JsonString（JSON 编码字符串，非对象）——
 * 映射时 JSON.parse 为对象，解析失败/为空时兜底 {}。
 */

export interface WorkflowRunItem {
	id: string;
	status: WorkflowRunStatus;
	definitionId: string;
	/** 执行产物 facts（JsonString 解析后的对象；无产物为空对象） */
	facts: Record<string, unknown>;
	startedAt: string | null;
	finishedAt: string | null;
}

/** JsonString → 对象；null/空串/非法 JSON 兜底 {}（展示页通用渲染，不假定结构） */
export function parseJsonString(raw: string | null | undefined): Record<string, unknown> {
	if (!raw) return {};
	try {
		const parsed: unknown = JSON.parse(raw);
		return parsed && typeof parsed === "object" && !Array.isArray(parsed)
			? (parsed as Record<string, unknown>)
			: {};
	} catch {
		return {};
	}
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

/** 后端 WorkflowRun → 前端展示项（facts 解析为对象） */
export function mapWorkflowRun(r: WorkflowRun): WorkflowRunItem {
	return {
		id: r.id,
		status: r.status,
		definitionId: r.definitionId,
		facts: parseJsonString(r.facts),
		startedAt: r.startedAt,
		finishedAt: r.finishedAt,
	};
}

/**
 * 获取 run 列表（#40 展示页按 workspace；#117 audit 页可免 workspace 全量 + status/时间筛选）。
 * filter 用 eq 内层包装；read policy 经 workspace → memberships 路径，
 * 成员可见本工作台 run，非成员空结果（无需额外 query 内 filter）。
 * #117：filters.status → status.eq；filters.insertedAfter/Before → startedAt 比较器
 * （自动 filter 无 insertedAt；startedAt 与 audit 页时间列一致）。
 */
export async function fetchWorkflowRuns(
	workspaceId?: string,
	opts?: { first?: number; after?: string; filters?: AuditFilters },
): Promise<WorkflowRunItem[]> {
	const first = opts?.first ?? 50;
	const filter: WorkflowRunFilter = {};
	if (workspaceId) {
		filter.workspaceId = { eq: workspaceId };
	}
	if (opts?.filters?.status) {
		filter.status = { eq: opts.filters.status };
	}
	if (opts?.filters?.insertedAfter || opts?.filters?.insertedBefore) {
		filter.startedAt = {
			...(opts.filters.insertedAfter
				? { greaterThanOrEqual: opts.filters.insertedAfter }
				: {}),
			...(opts.filters.insertedBefore
				? { lessThanOrEqual: opts.filters.insertedBefore }
				: {}),
		};
	}

	const variables: { filter: WorkflowRunFilter; first?: number; after?: string } = {
		filter,
		first,
	};
	if (opts?.after) {
		variables.after = opts.after;
	}

	const { data } = await client.query({
		query: LIST_WORKFLOW_RUNS,
		variables,
		// #23：请求超时——GraphQL 端点挂起时中止请求，让页面落到错误态而非无限 loading。
		// Apollo 经 context.fetchOptions 把 signal 透传给 fetch（createHttpLink）。
		context: { fetchOptions: { signal: timeoutSignal() } },
	});

	const conn: WorkflowRunConnection | null | undefined = data?.listWorkflowRuns;
	if (!conn || !Array.isArray(conn.results)) return [];
	return conn.results.map(mapWorkflowRun);
}
