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

/** 步骤读取面条目（plan 020 U3：后端 steps JsonString 解析；output_schema 缺失为 null） */
export interface WorkflowRunStep {
	stepKey: string;
	title: string;
	type: string;
	/** output_schema 宽松形状（数组字段列表 / 单字段描述符 / 映射；不可解析为 null） */
	outputSchema: unknown;
}

export interface WorkflowRunItem {
	id: string;
	status: WorkflowRunStatus;
	workspaceId?: string;
	definitionType: string;
	startedAt: string | null;
	finishedAt: string | null;
	insertedAt?: string;
	/** Deprecated compatibility fields for local type-only helpers; never populated from audit API. */
	definitionId?: string;
	facts?: Record<string, unknown>;
	steps?: WorkflowRunStep[];
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

/** JsonString 数组 → 步骤条目（每项 JSON 编码 {step_key,title,type,output_schema}；宽松解析） */
export function parseSteps(raw: string[] | null | undefined): WorkflowRunStep[] {
	if (!Array.isArray(raw)) return [];
	const steps: WorkflowRunStep[] = [];
	for (const item of raw) {
		try {
			const parsed: unknown = JSON.parse(item);
			if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) continue;
			const obj = parsed as Record<string, unknown>;
			const stepKey = obj.step_key;
			if (typeof stepKey !== "string") continue;
			steps.push({
				stepKey,
				title: typeof obj.title === "string" ? obj.title : stepKey,
				type: typeof obj.type === "string" ? obj.type : "",
				outputSchema:
					obj.output_schema && typeof obj.output_schema === "object"
						? (obj.output_schema as Record<string, unknown>)
						: null,
			});
		} catch {
			// 单条非法 JSON 跳过（宽松兼容），不拖垮整批
		}
	}
	return steps;
}

/** 后端 WorkflowRun → 前端展示项（facts/steps 解析为对象） */
export function mapWorkflowRun(r: WorkflowRun): WorkflowRunItem {
	return {
		id: r.id,
		status: r.status,
		workspaceId: r.workspaceId,
		definitionType: r.definitionType ?? r.definitionId ?? "unknown",
		startedAt: r.startedAt,
		finishedAt: r.finishedAt,
		insertedAt: r.insertedAt,
	};
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
		? data.platformWorkflowAudit.map(mapWorkflowRun)
		: [];
}
