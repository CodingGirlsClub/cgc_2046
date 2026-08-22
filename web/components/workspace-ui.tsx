"use client";

/**
 * Workspace 展示组件单源（首页 / 工作区概览页共用，2026-08-02 issue #74 抽取）。
 *
 * 首页工作台页（app/page.tsx）与工作区概览页（app/w/[slug]/page.tsx）共享的
 * 展示组件/常量落在这里；新增工作区展示组件一律先查此处。
 * 图标一律使用共享 Icon 集（components/icons.tsx），禁止页面内手抄 SVG。
 */

import { useTranslations } from "next-intl";
import { Icon, type IconName } from "@/components/icons";
import { ROLE_LABEL } from "@/lib/graphql/workspace";
import type { WorkspaceListItem } from "@/lib/workspaces";

export type WorkspaceStatus = "active" | "pending" | "invited";

export const STATUS_META: Record<
	WorkspaceStatus,
	{ labelKey: string; className: string }
> = {
	active: { labelKey: "status.active", className: "workspace-status--active" },
	pending: { labelKey: "status.pending", className: "workspace-status--pending" },
	invited: { labelKey: "status.invited", className: "workspace-status--invited" },
};

export function getWorkspaceStatus(ws: WorkspaceListItem): WorkspaceStatus {
	if (ws.membershipStatus) return ws.membershipStatus;
	return ws.myRoleNames?.length ? "active" : "invited";
}

export function getWorkspaceRoles(ws: WorkspaceListItem): string[] {
	const roles = ws.myRoleNames?.length ? ws.myRoleNames : (ws.roles ?? []);
	return roles.map(
		(role) => ROLE_LABEL[role as keyof typeof ROLE_LABEL] ?? role,
	);
}

export function workspaceInitials(ws: WorkspaceListItem): string {
	const words = ws.name.trim().split(/\s+/).filter(Boolean);
	const latinWords = words.filter((word) => /^[A-Za-z]/.test(word));
	if (latinWords.length >= 2)
		return latinWords
			.slice(0, 2)
			.map((word) => word[0])
			.join("")
			.toUpperCase();
	if (latinWords.length === 1 && latinWords[0].length >= 2)
		return latinWords[0].slice(0, 2).toUpperCase();
	return ws.name.replace(/\s/g, "").slice(0, 2) || "WS";
}

export function WorkspaceAvatar({
	ws,
	large = false,
	small = false,
}: {
	ws: WorkspaceListItem;
	large?: boolean;
	small?: boolean;
}) {
	const status = getWorkspaceStatus(ws);
	return (
		<span
			className={`workspace-avatar workspace-avatar--${status} ${large ? "workspace-avatar--large" : ""} ${small ? "workspace-avatar--small" : ""}`}
		>
			{workspaceInitials(ws)}
		</span>
	);
}

export function StatusTag({
	status,
	lowercase = false,
}: {
	status: WorkspaceStatus;
	lowercase?: boolean;
}) {
	const t = useTranslations("workspace");
	const meta = STATUS_META[status];
	return (
		<span className={`workspace-status ${meta.className}`}>
			<span className="workspace-status__dot" />
			{lowercase ? status : t(meta.labelKey)}
		</span>
	);
}

export function RoleChips({
	roles,
	member = false,
}: {
	roles: string[];
	/**
	 * true = 查看者持有活跃成员资格：空角色显示基准身份「成员」chip
	 * （RBAC 语义：tutor 等是差异标签，成员资格本身即基准能力）；
	 * false（待加入 / 只读审计访客）保持「暂无角色」。
	 */
	member?: boolean;
}) {
	const t = useTranslations("workspace");
	const labelsT = useTranslations();
	if (roles.length === 0) {
		if (member)
			return (
				<span className="workspace-role-chips">
					<span className="workspace-role-chip">{t("memberRole")}</span>
				</span>
			);
		return <span className="workspace-empty-value">{t("noRoles")}</span>;
	}
	return (
		<span className="workspace-role-chips">
			{roles.map((role) => (
				<span className="workspace-role-chip" key={role}>
					{labelsT(role)}
				</span>
			))}
		</span>
	);
}

export function InfoCard({
	icon,
	title,
	children,
	className = "",
}: {
	icon: IconName;
	title: string;
	children: React.ReactNode;
	className?: string;
}) {
	return (
		<section className={`workspace-info-card ${className}`}>
			<span className="workspace-info-card__icon">
				<Icon name={icon} />
			</span>
			<div className="workspace-info-card__body">
				<p className="workspace-info-card__title">{title}</p>
				{children}
			</div>
		</section>
	);
}
