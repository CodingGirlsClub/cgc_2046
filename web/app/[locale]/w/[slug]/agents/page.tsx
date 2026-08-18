"use client";

/**
 * plan 020 U2（D-20c）Agents 工作面 /w/[slug]/agents。
 *
 * 三区（自上而下）：
 * ① 待办交接区（置顶）：本工作台 learning run 的待办 manual 步骤（active run：
 *    running/waiting；facts 无该 step_key 即待办），每项「复制交接文本」按钮
 *    （workspace slug(id) / run / step / save_step_output 工具提示）。
 * ② 活动流：本人 MCP 工具调用时间轴（myWorkspaceToolCalls——仅本人，隐私最小面，
 *    无 params）；status 色点 + 耗时。
 * ③ 连接引导：无 active token 时展示（fetchMyMcpTokens），链 MCP tab 签发 +
 *    OpenClacky tab 引导（不复制内容）。
 *
 * 数据：listWorkflowRuns（U3 读取面，含 definition.type + steps）+ myMcpTokens +
 * myWorkspaceToolCalls。
 */

import { useEffect, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import WorkspaceShell from "@/components/workspace-shell";
import { Icon } from "@/components/icons";
import StepHandoffCopy from "@/components/step-handoff-copy";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { fetchWorkflowRuns, type WorkflowRunItem, type WorkflowRunStep } from "@/lib/workflows";
import { fetchMyMcpTokens, type McpTokenItem } from "@/lib/mcp";
import { fetchMyWorkspaceToolCalls, type AgentActivityItem } from "@/lib/agents";

/** 活动流状态展示元信息（色点 class + 中文 label） */
const ACTIVITY_STATUS_META: Record<string, { className: string; label: string }> = {
	ok: { className: "agents-activity-dot--ok", label: "成功" },
	error: { className: "agents-activity-dot--error", label: "失败" },
	needs_confirmation: { className: "agents-activity-dot--pending", label: "待确认" },
	forbidden: { className: "agents-activity-dot--error", label: "被拒" },
};

function activityMeta(status: string) {
	return ACTIVITY_STATUS_META[status] ?? { className: "agents-activity-dot--muted", label: status };
}

interface TodoItem {
	run: WorkflowRunItem;
	step: WorkflowRunStep;
}

/**
 * 待办推导：learning 类型 + active 状态（learning run 协议路径下 running 即
 * 等待学员产出的常态，waiting 为兼容兜底）+ manual 步骤且 facts 未写该 step_key。
 */
export function deriveTodos(runs: WorkflowRunItem[]): TodoItem[] {
	const todos: TodoItem[] = [];
	for (const run of runs) {
		if (run.definitionType !== "learning") continue;
		if (run.status !== "running" && run.status !== "waiting") continue;
		for (const step of run.steps) {
			if (step.type !== "manual") continue;
			if (Object.prototype.hasOwnProperty.call(run.facts, step.stepKey)) continue;
			todos.push({ run, step });
		}
	}
	return todos;
}

function formatActivityTime(iso: string): string {
	return new Date(iso).toLocaleString("zh-CN", {
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
	});
}

function TodoSection({
	todos,
	slug,
	workspaceId,
}: {
	todos: TodoItem[];
	slug: string;
	workspaceId: string;
}) {
	if (todos.length === 0) {
		return (
			<section className="agents-card" data-testid="agents-todos-empty">
				<div className="agents-section-head">
					<h2>待办交接</h2>
					<span className="agents-section-hint">本工作台学习 run 等待助手产出的步骤</span>
				</div>
				<p className="agents-todos-none">当前没有待办步骤 🎉</p>
			</section>
		);
	}

	return (
		<section className="agents-card" data-testid="agents-todos">
			<div className="agents-section-head">
				<h2>待办交接</h2>
				<span className="agents-section-hint">把待办步骤交接给你的助手执行</span>
			</div>
			<ul className="agents-todos-list">
				{todos.map(({ run, step }) => (
					<li key={`${run.id}:${step.stepKey}`} className="agents-todo" data-testid="agents-todo-item">
						<div className="agents-todo__info">
							<span className="agents-todo__title">{step.title || step.stepKey}</span>
							<span className="agents-todo__meta">
								run {run.id.slice(0, 8)} · {run.status}
							</span>
						</div>
						<StepHandoffCopy
							workspaceSlug={slug}
							workspaceId={workspaceId}
							runId={run.id}
							stepKey={step.stepKey}
						/>
					</li>
				))}
			</ul>
			<p className="agents-multihost-hint">粘贴给你的 OpenClacky / opencode / omp 助手</p>
		</section>
	);
}

function ActivitySection({ items }: { items: AgentActivityItem[] }) {
	if (items.length === 0) {
		return (
			<section className="agents-card" data-testid="agents-activity-empty">
				<div className="agents-section-head">
					<h2>活动流</h2>
					<span className="agents-section-hint">本工作台内你自己的工具调用（隐私最小面）</span>
				</div>
				<p className="agents-activity-none">暂无活动——在 OpenClacky / opencode / omp 里调用平台工具后，记录会显示在这里。</p>
			</section>
		);
	}

	return (
		<section className="agents-card" data-testid="agents-activity">
			<div className="agents-section-head">
				<h2>活动流</h2>
				<span className="agents-section-hint">本工作台内你自己的工具调用（隐私最小面）</span>
			</div>
			<ul className="agents-activity-timeline">
				{items.map((item) => {
					const meta = activityMeta(item.status);
					return (
						<li key={item.id} className="agents-activity-item" data-testid="agents-activity-item">
							<span className={`agents-activity-dot ${meta.className}`} aria-hidden="true" />
							<div className="agents-activity__body">
								<div className="agents-activity__row">
									<code className="agents-activity__tool">{item.tool}</code>
									<span className="agents-activity__status">{meta.label}</span>
								</div>
								<div className="agents-activity__meta">
									<span>{formatActivityTime(item.insertedAt)}</span>
									{item.latencyMs !== null && <span>{item.latencyMs}ms</span>}
								</div>
								{item.errorMessage && (
									<p className="agents-activity__error">{item.errorMessage}</p>
								)}
							</div>
						</li>
					);
				})}
			</ul>
		</section>
	);
}

function ConnectSection({ slug }: { slug: string }) {
	return (
		<section className="agents-card" data-testid="agents-connect">
			<div className="agents-section-head">
				<h2>连接助手</h2>
				<span className="agents-section-hint">还没有可用的连接 token</span>
			</div>
			<p className="agents-connect-desc">
				连接 OpenClacky / opencode / omp 后，助手才能在本工作台读取上下文、写回步骤产出。
			</p>
			<div className="agents-connect-actions">
				<Link
					href={`/w/${slug}/settings/integrations/agents/mcp`}
					className="join-button join-button--primary"
				>
					<Icon name="plus" />
					签发 token
				</Link>
				<Link
					href={`/w/${slug}/settings/integrations/agents/openclacky`}
					className="join-button"
				>
					OpenClacky 接入引导
				</Link>
			</div>
		</section>
	);
}

export default function WorkspaceAgentsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { authed, confirmed } = useAuthed();
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);

	const [runs, setRuns] = useState<WorkflowRunItem[]>([]);
	const [activity, setActivity] = useState<AgentActivityItem[]>([]);
	const [hasActiveToken, setHasActiveToken] = useState(false);
	const [loading, setLoading] = useState(true);
	const [errorMsg, setErrorMsg] = useState<string | null>(null);
	const [runsWorkspaceId, setRunsWorkspaceId] = useState<string | null>(null);

	const wsId = ws?.id;

	useEffect(() => {
		if (!confirmed || !authed) return;
		if (!wsId) return;

		let cancelled = false;

		Promise.all([
			fetchWorkflowRuns(wsId),
			fetchMyWorkspaceToolCalls(wsId),
			fetchMyMcpTokens(),
		])
			.then(([runsResult, activityResult, tokens]) => {
				if (cancelled) return;
				setRuns(runsResult);
				setActivity(activityResult);
				setHasActiveToken(tokens.some((t: McpTokenItem) => t.status === "active"));
				setRunsWorkspaceId(wsId);
				setErrorMsg(null);
			})
			.catch((error: unknown) => {
				if (cancelled) return;
				setRunsWorkspaceId(wsId);
				setErrorMsg(error instanceof Error ? error.message : "加载 Agents 工作面失败");
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, wsId]);

	const currentRuns = runsWorkspaceId === wsId ? runs : null;
	const currentError = runsWorkspaceId === wsId ? errorMsg : null;

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>Agents</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>Agents</h1>
						<p>助手活动、待办交接与连接引导</p>
					</div>
				</header>

				{currentError && (
					<div className="members-error" role="alert">
						{currentError}
					</div>
				)}

				{wsLoading || loading || currentRuns === null ? (
					<div className="workflows-loading" data-testid="agents-loading">
						加载中…
					</div>
				) : currentError ? null : wsId ? (
					<div className="agents-grid" data-testid="agents-page">
						<TodoSection todos={deriveTodos(currentRuns)} slug={slug} workspaceId={wsId} />
						<ActivitySection items={activity} />
						{!hasActiveToken && <ConnectSection slug={slug} />}
					</div>
				) : null}
			</div>
		</WorkspaceShell>
	);
}
