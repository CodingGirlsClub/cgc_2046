"use client";

/**
 * plan 020 U2（D-20c）Agents 工作面 /w/[slug]/agents。
 *
 * 两区（自上而下）：
 * ① 活动流：本人 MCP 工具调用时间轴（myWorkspaceToolCalls——仅本人，隐私最小面，
 *    无 params）；status 色点 + 耗时。
 * ② 连接引导：无 active token 时展示（fetchMyMcpTokens），链 MCP tab 签发 +
 *    OpenClacky tab 引导（不复制内容）。
 *
 * 数据：myMcpTokens + myWorkspaceToolCalls。隐私切换后本页不再读取 raw
 * WorkflowRun（platformWorkflowAudit 仅 Platform Admin 审计面可用），原待办
 * 交接区随之退役；学习进度入口在「我的学习」（myLearningRuns）。
 */

import { useEffect, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import WorkspaceShell from "@/components/workspace-shell";
import { Icon } from "@/components/icons";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { fetchMyMcpTokens, type McpTokenItem } from "@/lib/mcp";
import { fetchMyWorkspaceToolCalls, type AgentActivityItem } from "@/lib/agents";

/** 活动流状态展示元信息（色点 class + 中文 label） */
const ACTIVITY_STATUS_META: Record<string, { className: string; labelKey: string }> = {
	ok: { className: "agents-activity-dot--ok", labelKey: "activityStatusOk" },
	error: { className: "agents-activity-dot--error", labelKey: "activityStatusError" },
	needs_confirmation: { className: "agents-activity-dot--pending", labelKey: "activityStatusPending" },
	forbidden: { className: "agents-activity-dot--error", labelKey: "activityStatusForbidden" },
};

function activityMeta(status: string) {
	return ACTIVITY_STATUS_META[status] ?? { className: "agents-activity-dot--muted", labelKey: status };
}


function formatActivityTime(iso: string): string {
	return new Date(iso).toLocaleString("zh-CN", {
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
	});
}


function ActivitySection({ items }: { items: AgentActivityItem[] }) {
	const t = useTranslations("workspaceAgents");
	if (items.length === 0) {
		return (
			<section className="agents-card" data-testid="agents-activity-empty">
				<div className="agents-section-head">
					<h2>{t("activityTitle")}</h2>
					<span className="agents-section-hint">{t("activityHint")}</span>
				</div>
				<p className="agents-activity-none">{t("activityEmpty")}</p>
			</section>
		);
	}

	return (
		<section className="agents-card" data-testid="agents-activity">
			<div className="agents-section-head">
				<h2>{t("activityTitle")}</h2>
				<span className="agents-section-hint">{t("activityHint")}</span>
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
									<span className="agents-activity__status">{t(meta.labelKey)}</span>
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
	const t = useTranslations("workspaceAgents");
	return (
		<section className="agents-card" data-testid="agents-connect">
			<div className="agents-section-head">
				<h2>{t("connectTitle")}</h2>
				<span className="agents-section-hint">{t("connectHint")}</span>
			</div>
			<p className="agents-connect-desc">
				{t("connectDesc")}
			</p>
			<div className="agents-connect-actions">
				<Link
					href={`/w/${slug}/settings/integrations/agents/mcp`}
					className="join-button join-button--primary"
				>
					<Icon name="plus" />
					{t("issueToken")}
				</Link>
				<Link
					href={`/w/${slug}/settings/integrations/agents/openclacky`}
					className="join-button"
				>
					{t("openclackyGuide")}
				</Link>
			</div>
		</section>
	);
}

export default function WorkspaceAgentsPage() {
	const t = useTranslations("workspaceAgents");
	const tCommon = useTranslations("common");
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { authed, confirmed } = useAuthed();
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);

	const [activity, setActivity] = useState<AgentActivityItem[]>([]);
	const [hasActiveToken, setHasActiveToken] = useState(false);
	const [loading, setLoading] = useState(true);
	const [errorMsg, setErrorMsg] = useState<string | null>(null);
	/** 数据归属的 wsId：slug 切换后旧工作区数据不落屏（staleness 守卫） */
	const [loadedWsId, setLoadedWsId] = useState<string | null>(null);

	const wsId = ws?.id;

	useEffect(() => {
		if (!confirmed || !authed) return;
		if (!wsId) return;

		let cancelled = false;

		Promise.all([
			fetchMyWorkspaceToolCalls(wsId),
			fetchMyMcpTokens(),
		])
			.then(([activityResult, tokens]) => {
				if (cancelled) return;
				setActivity(activityResult);
				setHasActiveToken(tokens.some((t: McpTokenItem) => t.status === "active"));
				setLoadedWsId(wsId);
				setErrorMsg(null);
			})
			.catch((error: unknown) => {
				if (cancelled) return;
				setLoadedWsId(wsId);
				setErrorMsg(error instanceof Error ? error.message : t("loadFailed"));
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, wsId, t]);

	const currentError = loadedWsId === wsId ? errorMsg : null;

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>{t("title")}</strong>
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

				{wsLoading || loading || loadedWsId !== wsId ? (
					<div className="workflows-loading" data-testid="agents-loading">
						{t("loading")}
					</div>
				) : currentError ? null : wsId ? (
					<div className="agents-grid" data-testid="agents-page">
						<ActivitySection items={activity} />
						{!hasActiveToken && <ConnectSection slug={slug} />}
					</div>
				) : null}
			</div>
		</WorkspaceShell>
	);
}
