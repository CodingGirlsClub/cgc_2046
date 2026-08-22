"use client";

/**
 * #74 工作区概览页 /w/[slug]。
 *
 * #63 占位页已被本页取代：接入 WorkspaceShell（壳负责未认证重定向、侧栏、
 * 退出登录与「工作区不可访问」态），页面退化为壳内纯内容 —— Hero / 信息卡
 * 网格 / 管理入口。
 *
 * 数据：只消费真实数据（useWorkspaceBySlug → fetchMyWorkspaces 唯一路径，
 * #1 mock 双轨已删除，2026-08-02 决策）；未解析完成时渲染骨架，绝不渲染
 * 假数据。未知 slug 的「工作区不可访问」由壳 requireWs 渲染，页面不处理。
 */

import { useEffect, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { markInviteShown, useOnboardingState } from "@/lib/onboarding";
import { JOIN_POLICY_HINT, JOIN_POLICY_LABEL } from "@/lib/graphql/workspace";
import WorkspaceShell from "@/components/workspace-shell";
import OnboardingConnectCard from "@/components/onboarding-connect-card";
import OnboardingInviteModal from "@/components/onboarding-invite-modal";
import { Icon } from "@/components/icons";
import { canSeeByKey } from "@/components/workspace-nav";
import {
	getWorkspaceRoles,
	getWorkspaceStatus,
	InfoCard,
	RoleChips,
	StatusTag,
	WorkspaceAvatar,
} from "@/components/workspace-ui";

export default function WorkspacePage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const t = useTranslations("workspaceOverview");
	const bcT = useTranslations("common");
	const labelsT = useTranslations();
	const { ws, loading: wsLoading, readOnlyVisitor } = useWorkspaceBySlug(slug);
	const onboarding = useOnboardingState();
	// KTD4 session 旗标（每 session 每用户最多自动弹一次，按 userId 命名空间）由
	// useOnboardingState 在 userId 就绪时一次性快照（inviteShownThisSession）；
	// 本挂载内被用户关闭（再看看/已拒绝/ Esc /遮罩）后 inviteClosed 置 true，不再重弹
	const [inviteClosed, setInviteClosed] = useState(false);

	// 管理入口卡与侧栏/Tab 条同源门控（plan 016 SETTINGS_NAV 注册表）：
	// 成员与角色 / 权限映射 = list_members，普通成员不渲染整卡
	const abilities = ws?.myAbilities ?? [];
	const showMembersCard = canSeeByKey("members", abilities);
	const showPermissionsCard = canSeeByKey("permissions", abilities);
	// 活跃成员空角色显示基准身份「成员」；待加入 / 只读审计访客保持「暂无角色」
	const isActiveMember = ws ? getWorkspaceStatus(ws) === "active" : false;

	// 首公里 onboarding 触点门控（plan first-mile-onboarding U3，KTD5 fail-closed）：
	// onboarding 数据未就绪（loading/error）/ 非 active 成员 / readOnlyVisitor → 不弹不挂卡
	const onboardingReady = !onboarding.loading && !onboarding.error;
	const onboardingEligible =
		onboardingReady && isActiveMember && !readOnlyVisitor;

	// 邀请模态：每次登录弹直到明确拒绝（session-settled）——全真才弹。
	// 开态为派生态（react-hooks/set-state-in-effect：不在 effect 里同步 setState），
	// effect 只做「展示即写 session 旗标」（KTD4）
	const inviteOpen =
		onboardingEligible &&
		!onboarding.hasActiveToken &&
		!onboarding.dismissed &&
		!onboarding.inviteShownThisSession &&
		!inviteClosed;
	useEffect(() => {
		// inviteOpen 为真时 onboarding 已就绪（onboardingReady），userId 必非 null
		if (inviteOpen) markInviteShown(onboarding.userId);
	}, [inviteOpen, onboarding.userId]);

	// 等待首联态自动撤卡（P2）：宿主在外部完成首次 MCP 调用写入 lastUsedAt 后，
	// 本页免整页刷新。主场景是用户切去终端配置宿主、首联完成、切回浏览器——
	// 监听 window focus 与 visibilitychange（变 visible 时）；30s interval 兜底
	// 分屏不切窗 / 宿主自动连接（回调内判 visible 才刷）。态退出（connected 置真
	// 或不再 eligible）由 effect 清理拆除监听与 interval。
	// 范围纪律：仅等待首联态挂监听——邀请态与已接入态不轮询。
	const awaitingFirstConnect =
		onboardingEligible && onboarding.hasActiveToken && !onboarding.connected;
	const { refreshSilently } = onboarding;
	useEffect(() => {
		if (!awaitingFirstConnect) return;
		const onFocus = () => refreshSilently();
		const onVisible = () => {
			if (document.visibilityState === "visible") refreshSilently();
		};
		window.addEventListener("focus", onFocus);
		document.addEventListener("visibilitychange", onVisible);
		const timer = setInterval(() => {
			if (document.visibilityState === "visible") refreshSilently();
		}, 30_000);
		return () => {
			window.removeEventListener("focus", onFocus);
			document.removeEventListener("visibilitychange", onVisible);
			clearInterval(timer);
		};
	}, [awaitingFirstConnect, refreshSilently]);

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={bcT("breadcrumbAria")}>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>{t("breadcrumbOverview")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("title")}</h1>
						<p>{t("subtitle")}</p>
					</div>
				</header>

				{wsLoading ? (
					<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
				) : ws ? (
					<>
						{/* Hero：头像 / 名称 / slug / Active / 角色 chips / 加入方式（对标首页 workspace-detail-hero） */}
						<div className="workspace-detail-hero">
							<WorkspaceAvatar ws={ws} large />
							<div className="workspace-detail-hero__body">
								<h2>{ws.name}</h2>
								<p className="workspace-slug">{ws.slug}</p>
								<div className="workspace-detail-hero__meta">
									<StatusTag status="active" />
									<RoleChips
										roles={getWorkspaceRoles(ws)}
										member={isActiveMember}
									/>
								</div>
							</div>
							<div className="workspace-detail-hero__policy">
								<span>{t("joinMethod")}</span>
								<strong
									className={`workspace-policy workspace-policy--${ws.joinPolicy}`}
								>
									{labelsT(JOIN_POLICY_LABEL[ws.joinPolicy])}
								</strong>
								<p>{labelsT(JOIN_POLICY_HINT[ws.joinPolicy])}</p>
							</div>
						</div>

						{/* 信息卡网格：加入方式 / 我的角色 / 社区规模 */}
						<div className="workspace-info-grid">
							<InfoCard icon="community" title={t("joinMethod")}>
								<strong className="workspace-info-card__value">
									{labelsT(JOIN_POLICY_LABEL[ws.joinPolicy])}
								</strong>
								<p>{labelsT(JOIN_POLICY_HINT[ws.joinPolicy])}</p>
							</InfoCard>
							<InfoCard icon="role" title={t("myRoles")}>
								<RoleChips
									roles={getWorkspaceRoles(ws)}
									member={isActiveMember}
								/>
								<p>{t("rolesHint")}</p>
							</InfoCard>
							<InfoCard icon="members" title={t("community")}>
								<strong
									className="workspace-info-card__value"
									data-testid="workspace-member-count"
								>
									{ws.memberCount != null ? t("memberCount", { count: ws.memberCount }) : "—"}
								</strong>
								<p>{ws.sponsorshipEnabled ? t("sponsorshipOpen") : t("sponsorshipClosed")}</p>
							</InfoCard>
						</div>

						{/* 管理入口：成员与角色 / 权限映射。
						    整卡按能力门控（与侧栏同源 canSeeByKey，list_members），普通成员不渲染；
						    可见即可管理（list_members 与 assign_roles 同属 Owner/Admin，矩阵同源） */}
						{(showMembersCard || showPermissionsCard) && (
							<div className="mt-6 grid gap-4 sm:grid-cols-2">
								{showMembersCard && (
									<Link
										href={`/w/${slug}/settings/members`}
										className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
									>
										<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
											<Icon name="users" />
										</span>
										<span className="min-w-0 flex-1">
											<span className="block text-sm font-medium text-ink">
												{t("membersAndRoles")}
											</span>
											<span className="mt-1 block text-[13px] leading-5 text-ink-3">
												{t("membersManage")}
											</span>
										</span>
										<span className="flex-none text-ink-3">
											<Icon name="arrow" />
										</span>
									</Link>
								)}
								{showPermissionsCard && (
									<Link
										href={`/w/${slug}/settings/permissions`}
										className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
									>
										<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
											<Icon name="shield" />
										</span>
										<span className="min-w-0 flex-1">
											<span className="block text-sm font-medium text-ink">
												{t("permissionMapping")}
											</span>
											<span className="mt-1 block text-[13px] leading-5 text-ink-3">
												{t("permissionMappingDesc")}
											</span>
										</span>
										<span className="flex-none text-ink-3">
											<Icon name="arrow" />
										</span>
									</Link>
								)}
							</div>
						)}

						{/* 首公里常驻接入卡（R8）：未接入 → 邀请态；已签发未首联 → 等待提醒态；
						    connected 后不挂；dismissed 不影响（R2 拒绝模态后的常驻入口） */}
						{onboardingEligible &&
							(!onboarding.hasActiveToken || !onboarding.connected) && (
								<div className="mt-4">
									<OnboardingConnectCard
										slug={slug}
										hasActiveToken={onboarding.hasActiveToken}
									/>
								</div>
							)}

						{/* 教研产出入口（切片 C 已落地，见 workflows 页；plan 016 替换过期占位卡）。
						    报名/赞助（切片 E）仍为占位：视觉降级虚线边框 + 「即将开放」角标 */}
						<div className="mt-4 grid gap-4 sm:grid-cols-2">
							{/* plan 020 U1：Agents 与助手协作引导卡 → /w/[slug]/agents */}
							<Link
								href={`/w/${slug}/agents`}
								className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
							>
								<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
									<Icon name="activity" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block text-sm font-medium text-ink">
										{t("agentsTitle")}
									</span>
									<span className="mt-1 block text-[13px] leading-5 text-ink-3">
										{t("agentsDesc")}
									</span>
								</span>
								<span className="flex-none text-ink-3">
									<Icon name="arrow" />
								</span>
							</Link>
							<Link
								href={`/w/${slug}/workflows`}
								className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
							>
								<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
									<Icon name="book" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block text-sm font-medium text-ink">
										{t("workflowTitle")}
									</span>
									<span className="mt-1 block text-[13px] leading-5 text-ink-3">
										{t("workflowDesc")}
									</span>
								</span>
								<span className="flex-none text-ink-3">
									<Icon name="arrow" />
								</span>
							</Link>
							<Link
								href={`/w/${slug}/events`}
								className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
							>
								<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
									<Icon name="book" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block text-sm font-medium text-ink">{t("eventsTitle")}</span>
									<span className="mt-1 block text-[13px] leading-5 text-ink-3">
										{t("eventsDesc")}
									</span>
								</span>
								<span className="flex-none text-ink-3">
									<Icon name="arrow" />
								</span>
							</Link>
							<Link
								href={`/w/${slug}/courses`}
								className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
							>
								<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
									<Icon name="book" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block text-sm font-medium text-ink">{t("coursesTitle")}</span>
									<span className="mt-1 block text-[13px] leading-5 text-ink-3">
										{t("coursesDesc")}
									</span>
								</span>
								<span className="flex-none text-ink-3">
									<Icon name="arrow" />
								</span>
							</Link>
						</div>
					</>
				) : null}

				{/* 首公里邀请模态（R1/R2）：弹出条件全真才弹，见上方 inviteOpen 派生 */}
				{inviteOpen && (
					<OnboardingInviteModal
						slug={slug}
						onClose={() => setInviteClosed(true)}
					/>
				)}
			</div>
		</WorkspaceShell>
	);
}
