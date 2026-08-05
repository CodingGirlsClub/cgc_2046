"use client";

/**
 * settings 三子页（加入策略 / 加入审批 / 邀请管理）共享的页签导航。
 * 与 members/permissions 的 tab 模式一致；审批/邀请 tab 按 manage_members 过滤。
 */
import Link from "next/link";

export type SettingsTab = "policy" | "requests" | "invitations";

const TABS: { key: SettingsTab; label: string; href: (slug: string) => string }[] =
	[
		{ key: "policy", label: "加入策略", href: (s) => `/w/${s}/settings` },
		{ key: "requests", label: "加入审批", href: (s) => `/w/${s}/settings/requests` },
		{
			key: "invitations",
			label: "邀请管理",
			href: (s) => `/w/${s}/settings/invitations`,
		},
	];

export default function SettingsTabs({
	slug,
	current,
	canManage,
}: {
	slug: string;
	current: SettingsTab;
	/** 审批/邀请 tab 仅 manage_members 可见（与侧栏门控一致） */
	canManage: boolean;
}) {
	return (
		<nav className="ws-tabs" aria-label="加入管理页签">
			{TABS.map((tab) => {
				// 审批/邀请 tab 在非管理员视图隐藏（加入策略 tab 始终可见）
				if (tab.key !== "policy" && !canManage) return null;
				const selected = tab.key === current;
				return (
					<Link
						key={tab.key}
						href={tab.href(slug)}
						className={`ws-tab ${selected ? "ws-tab--selected" : ""}`}
						aria-current={selected ? "page" : undefined}
					>
						{tab.label}
					</Link>
				);
			})}
		</nav>
	);
}