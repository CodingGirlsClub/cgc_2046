"use client";

/**
 * #40 教研产出展示页 /w/[slug]/workflows（plan 020 U3/U4 升级）。
 *
 * 只读展示：列出该工作台的 workflow run：
 * - U3（#150 最小版 + #92）：RunCard 加步骤条（facts step_key 推导完成集、待办高亮）；
 *   learning 类型 + active（running/waiting）run 的待办 manual 步骤旁平台引导 + CTA
 *   （主动作 = 上下文交接复制，与 Agents 页共用组件；副链「去 Agents 页」+「连接设置」；
 *   research 类型不显示 CTA；多宿主文案）。
 * - U4（#93）：步骤产物按 output_schema schema 驱动渲染（SchemaOutputList），
 *   schema 缺失回退 FactsTree。
 * run 创建/状态流转不经 GraphQL 暴露（ResearchInstantiator 内部调用），
 * 本页仅消费 listWorkflowRuns 查询面。
 */

import { useEffect, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import WorkspaceShell from "@/components/workspace-shell";
import { InfoCard } from "@/components/workspace-ui";
import { Icon } from "@/components/icons";
import FactsTree from "@/components/facts-tree";
import SchemaOutputList from "@/components/schema-output-list";
import StepHandoffCopy from "@/components/step-handoff-copy";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { fetchWorkflowRuns, type WorkflowRunItem, type WorkflowRunStep } from "@/lib/workflows";
import { WORKFLOW_RUN_STATUS_LABEL } from "@/lib/graphql/workflow";

function stepDone(run: WorkflowRunItem, stepKey: string): boolean {
	return Object.prototype.hasOwnProperty.call(run.facts, stepKey);
}

/** 待办 manual 步骤（learning + active run）：CTA 判定与待办高亮共用 */
function pendingManualSteps(run: WorkflowRunItem): WorkflowRunStep[] {
	if (run.definitionType !== "learning") return [];
	if (run.status !== "running" && run.status !== "waiting") return [];
	return run.steps.filter((s) => s.type === "manual" && !stepDone(run, s.stepKey));
}

/** 步骤条：facts 推导完成集，待办高亮 */
function StepsBar({ run }: { run: WorkflowRunItem }) {
	const t = useTranslations("workspaceWorkflows");
	if (run.steps.length === 0) return null;
	return (
		<ul className="workflows-steps" data-testid="workflow-run-steps">
			{run.steps.map((step) => {
				const done = stepDone(run, step.stepKey);
				return (
					<li
						key={step.stepKey}
						className={`workflows-step ${done ? "workflows-step--done" : "workflows-step--pending"}`}
						data-testid={done ? "workflow-step-done" : "workflow-step-pending"}
					>
						<span className="workflows-step__dot" aria-hidden="true" />
						<span className="workflows-step__title">{step.title || step.stepKey}</span>
						{!done && <span className="workflows-step__tag">{t("todoTag")}</span>}
					</li>
				);
			})}
		</ul>
	);
}

/** 单个步骤的产物渲染：schema 驱动，缺失回退 FactsTree */
function StepOutput({ run, step }: { run: WorkflowRunItem; step: WorkflowRunStep }) {
	const output = run.facts[step.stepKey];
	if (output === undefined) return null;
	return (
		<div className="workflows-step-output" data-testid="workflow-step-output">
			<span className="workflows-step-output__title">{step.title || step.stepKey}</span>
			<div className="workflows-facts">
				<SchemaOutputList output={output} schema={step.outputSchema} />
			</div>
		</div>
	);
}

function RunCard({
	run,
	slug,
	workspaceId,
}: {
	run: WorkflowRunItem;
	slug: string;
	workspaceId: string;
}) {
	const t = useTranslations("workspaceWorkflows");
	const statusLabel = WORKFLOW_RUN_STATUS_LABEL[run.status] ?? run.status;
	const hasFacts = Object.keys(run.facts).length > 0;
	const pending = pendingManualSteps(run);
	const coveredKeys = new Set(run.steps.map((s) => s.stepKey));
	const extraFacts = Object.fromEntries(
		Object.entries(run.facts).filter(([key]) => !coveredKeys.has(key)),
	);
	const hasExtraFacts = Object.keys(extraFacts).length > 0;

	return (
		<InfoCard icon="activity" title={t("runTitle", { id: run.id.slice(0, 8) })}>
			<div className="workflows-run" data-testid="workflow-run">
				<div className="workflows-run__meta">
					<span
						className={`workflows-status workflows-status--${run.status}`}
						data-testid="workflow-run-status"
					>
						{statusLabel}
					</span>
					{run.definitionType && (
						<span className="workflows-run__type">{run.definitionType}</span>
					)}
					{run.startedAt && (
						<span className="workflows-run__time">
							{t("startedAt", { time: new Date(run.startedAt).toLocaleString("zh-CN") })}
						</span>
					)}
				</div>

				<StepsBar run={run} />

				{/* plan 020 U3.3：waiting/manual 待办步骤旁平台引导 + CTA（learning·active only） */}
				{pending.length > 0 && (
					<div className="workflows-cta" data-testid="workflow-run-cta">
						<p className="workflows-cta__lead">
							{t("ctaLead")}
						</p>
						<ul className="workflows-cta__steps">
							{pending.map((step) => (
								<li key={step.stepKey} className="workflows-cta__step">
									<span className="workflows-cta__step-title">
										{step.title || step.stepKey}
									</span>
									<StepHandoffCopy
										workspaceSlug={slug}
										workspaceId={workspaceId}
										runId={run.id}
										stepKey={step.stepKey}
									/>
								</li>
							))}
						</ul>
						<div className="workflows-cta__links">
							<Link href={`/w/${slug}/agents`}>{t("goAgents")}</Link>
							<span aria-hidden="true">·</span>
							<Link href={`/w/${slug}/settings/integrations/agents/mcp`}>
								{t("connectSettings")}
							</Link>
						</div>
					</div>
				)}

				{hasFacts ? (
					<div className="workflows-facts" data-testid="workflow-run-facts">
						{run.steps.map((step) => (
							<StepOutput key={step.stepKey} run={run} step={step} />
						))}
						{hasExtraFacts && <FactsTree data={extraFacts} />}
					</div>
				) : (
					<p className="workflows-run__empty">{t("emptyOutput")}</p>
				)}
			</div>
		</InfoCard>
	);
}

export default function WorkspaceWorkflowsPage() {
	const t = useTranslations("workspaceWorkflows");
	const tCommon = useTranslations("common");
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { authed, confirmed } = useAuthed();
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);

	const [runs, setRuns] = useState<WorkflowRunItem[]>([]);
	// 初始 loading=true：effect 内不再同步 setState（react-hooks/set-state-in-effect），
	// 首个 fetch 完成前由归属守卫 currentRuns === null 兜底加载态
	const [loading, setLoading] = useState(true);
	const [errorMsg, setErrorMsg] = useState<string | null>(null);
	// 数据归属守卫：runs 属于哪个 workspace（wsId 变化时旧数据作废，回到 loading）
	const [runsWorkspaceId, setRunsWorkspaceId] = useState<string | null>(null);

	const wsId = ws?.id;

	useEffect(() => {
		if (!confirmed || !authed) return;
		if (!wsId) return;

		let cancelled = false;
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
				setErrorMsg(error instanceof Error ? error.message : t("loadFailed"));
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, wsId, t]);

	// 数据归属守卫：wsId 变化（或尚未解析）时旧 runs 不渲染
	const currentRuns = runsWorkspaceId === wsId ? runs : null;
	// #20：errorMsg 同样按归属守卫——runsWorkspaceId 由获胜 effect 提交（成功与
	// 失败分支都 set），旧 workspace 的失败不渲染到新 workspace 上。
	const currentError = runsWorkspaceId === wsId ? errorMsg : null;

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>{t("breadcrumbTitle")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("title")}</h1>
						<p>{t("subtitle")}</p>
					</div>
				</header>

				{currentError && (
					<div className="members-error" role="alert">
						{currentError}
					</div>
				)}

				{wsLoading || loading || currentRuns === null ? (
					<div className="workflows-loading" data-testid="workflows-loading">
						{t("loading")}
					</div>
				) : currentError ? null : currentRuns.length === 0 ? (
					<section className="workflows-empty" data-testid="workflows-empty">
						<Icon name="book" size={28} />
						<p>{t("empty")}</p>
						<span>{t("emptyDesc")}</span>
					</section>
				) : (
					<div className="workflows-list" data-testid="workflows-list">
						{currentRuns.map((run) => (
							<RunCard key={run.id} run={run} slug={slug} workspaceId={wsId ?? ""} />
						))}
					</div>
				)}
			</div>
		</WorkspaceShell>
	);
}
