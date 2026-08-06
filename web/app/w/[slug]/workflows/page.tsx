"use client";

/**
 * #40 教研产出展示页 /w/[slug]/workflows。
 *
 * 只读展示：列出该工作台的 workflow run（status + facts 递归树）。
 * run 创建/状态流转不经 GraphQL 暴露（ResearchInstantiator 内部调用），
 * 本页仅消费 listWorkflowRuns 查询面。
 */

import { useEffect, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import WorkspaceShell from "@/components/workspace-shell";
import { InfoCard } from "@/components/workspace-ui";
import { Icon } from "@/components/icons";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { fetchWorkflowRuns, type WorkflowRunItem } from "@/lib/workflows";
import { WORKFLOW_RUN_STATUS_LABEL } from "@/lib/graphql/workflow";

/**
 * facts 递归渲染（不假定结构）：map → 键值行（值嵌套则缩进子树）；
 * list → 编号列表；scalar → 文本。sub_workflow 嵌套 map 自然缩进。
 */
function FactsTree({ data }: { data: unknown }) {
	if (data === null || data === undefined) return null;

	if (Array.isArray(data)) {
		return (
			<ul className="workflows-facts-list">
				{data.map((item, index) => (
					<li key={index}>
						<span className="workflows-facts-index">{index + 1}.</span>
						<FactsTree data={item} />
					</li>
				))}
			</ul>
		);
	}

	if (typeof data === "object") {
		const entries = Object.entries(data as Record<string, unknown>);
		if (entries.length === 0) return <span className="workflows-facts-empty">—</span>;
		return (
			<ul className="workflows-facts-map">
				{entries.map(([key, value]) => (
					<li key={key} className="workflows-facts-row">
						<span className="workflows-facts-key">{key}</span>
						<span className="workflows-facts-value">
							<FactsTree data={value} />
						</span>
					</li>
				))}
			</ul>
		);
	}

	return <span>{String(data)}</span>;
}

function RunCard({ run }: { run: WorkflowRunItem }) {
	const statusLabel =
		WORKFLOW_RUN_STATUS_LABEL[run.status] ?? run.status;
	const hasFacts = Object.keys(run.facts).length > 0;

	return (
		<InfoCard icon="activity" title={`教研产出 #${run.id.slice(0, 8)}`}>
			<div className="workflows-run" data-testid="workflow-run">
				<div className="workflows-run__meta">
					<span
						className={`workflows-status workflows-status--${run.status}`}
						data-testid="workflow-run-status"
					>
						{statusLabel}
					</span>
					{run.startedAt && (
						<span className="workflows-run__time">
							开始于 {new Date(run.startedAt).toLocaleString("zh-CN")}
						</span>
					)}
				</div>
				{hasFacts ? (
					<div className="workflows-facts" data-testid="workflow-run-facts">
						<FactsTree data={run.facts} />
					</div>
				) : (
					<p className="workflows-run__empty">暂无执行产物</p>
				)}
			</div>
		</InfoCard>
	);
}

export default function WorkspaceWorkflowsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { authed, confirmed } = useAuthed();
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);

	const [runs, setRuns] = useState<WorkflowRunItem[]>([]);
	const [loading, setLoading] = useState(false);
	const [errorMsg, setErrorMsg] = useState<string | null>(null);
	// 数据归属守卫：runs 属于哪个 workspace（wsId 变化时旧数据作废，回到 loading）
	const [runsWorkspaceId, setRunsWorkspaceId] = useState<string | null>(null);

	const wsId = ws?.id;

	useEffect(() => {
		if (!confirmed || !authed) return;
		if (!wsId) return;

		let cancelled = false;
		setLoading(true);
		fetchWorkflowRuns(wsId)
			.then((items) => {
				if (cancelled) return;
				setRuns(items);
				setRunsWorkspaceId(wsId);
				setErrorMsg(null);
			})
			.catch((error: unknown) => {
				if (cancelled) return;
				setRuns([]);
				setRunsWorkspaceId(wsId);
				setErrorMsg(error instanceof Error ? error.message : "加载教研产出失败");
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, wsId]);

	// 数据归属守卫：wsId 变化（或尚未解析）时旧 runs 不渲染
	const currentRuns = runsWorkspaceId === wsId ? runs : null;

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>教研产出</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>教研产出</h1>
						<p>查看该工作台的教研 workflow 执行结果</p>
					</div>
				</header>

				{errorMsg && (
					<div className="members-error" role="alert">
						{errorMsg}
					</div>
				)}

				{wsLoading || loading || currentRuns === null ? (
					<div className="workflows-loading" data-testid="workflows-loading">
						加载中…
					</div>
				) : errorMsg ? null : currentRuns.length === 0 ? (
					<section className="workflows-empty" data-testid="workflows-empty">
						<Icon name="book" size={28} />
						<p>暂无教研产出</p>
						<span>教研 workflow 执行完成后，产物会显示在这里</span>
					</section>
				) : (
					<div className="workflows-list" data-testid="workflows-list">
						{currentRuns.map((run) => (
							<RunCard key={run.id} run={run} />
						))}
					</div>
				)}
			</div>
		</WorkspaceShell>
	);
}
