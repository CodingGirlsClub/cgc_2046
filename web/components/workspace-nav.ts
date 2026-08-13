/**
 * 设置子域导航目的地注册表（plan 016：导航能力门控单源化）。
 *
 * 侧栏（workspace-shell.tsx Workspace 组）/ 设置 Tab 条（members-tabs.tsx）/
 * 品牌下拉菜单（workspace-switcher-menu.tsx）共用同一份目的地清单与门控判定，
 * 避免同一入口多处硬编码、规则互相矛盾（历史问题：侧栏 list_members 门控 vs
 * 页面 manage_members 门控）。
 *
 * 能力字符串（list_members / manage_members / update_join_policy）是后端 RBAC
 * 契约的一部分；改动需同步 backend/priv/rbac_contract.json 与 web/lib/permissions.ts。
 * 缺省 ability = 恒显（不参与过滤）。
 */

import type { IconName } from "@/components/icons";

/** 侧栏激活态 section 名（由 pathname 派生，见 workspace-shell.tsx navSection） */
export type NavSection =
	| "overview"
	| "workflows"
	| "events"
	| "courses"
	| "members"
	| "settings-permissions"
	| "settings-join-policy"
	| "settings-requests"
	| "settings-invitations"
	| "settings-account-profile"
	| "settings-account-preferences"
	| "settings-integrations-agents"
	| null;

export interface NavDestination {
	key: string;
	label: string;
	href: (slug: string) => string;
	/** 需要的能力；缺省 = 恒显 */
	ability?: string;
	/** 所属分组（侧栏 Linear 分组用） */
	group: "personal" | "workspace";
	/** 侧栏激活态 section 名（侧栏用） */
	active?: NavSection;
	/** 侧栏图标名（侧栏用） */
	icon?: IconName;
	/** 是否出现在设置 Tab 条（members-tabs 等）；false = 仅侧栏入口（如活动） */
	settingsTab?: boolean;
}

export const SETTINGS_NAV: NavDestination[] = [
	{
		key: "events",
		label: "活动",
		href: (s) => `/w/${s}/events`,
		group: "workspace",
		active: "events",
		icon: "book",
		settingsTab: false,
	},
	{
		key: "courses",
		label: "课程",
		href: (s) => `/w/${s}/courses`,
		group: "workspace",
		active: "courses",
		icon: "guide",
		settingsTab: false,
	},
	{
		key: "members",
		label: "成员与角色",
		href: (s) => `/w/${s}/settings/members`,
		ability: "list_members",
		group: "workspace",
		active: "members",
		icon: "users",
	},
	{
		key: "permissions",
		label: "权限映射",
		href: (s) => `/w/${s}/settings/permissions`,
		ability: "list_members",
		group: "workspace",
		active: "settings-permissions",
		icon: "role",
	},
	{
		key: "policy",
		label: "加入策略",
		href: (s) => `/w/${s}/settings/join-policy`,
		group: "workspace",
		active: "settings-join-policy",
		icon: "settings",
	},
	{
		key: "requests",
		label: "加入审批",
		href: (s) => `/w/${s}/settings/requests`,
		ability: "manage_members",
		group: "workspace",
		active: "settings-requests",
		icon: "shield",
	},
	{
		key: "invitations",
		label: "邀请管理",
		href: (s) => `/w/${s}/settings/invitations`,
		ability: "manage_members",
		group: "workspace",
		active: "settings-invitations",
		icon: "invite",
	},
];

/** 某目的地对给定能力列表是否可见（无 ability = 恒显）。 */
export function canSee(
	dest: Pick<NavDestination, "ability">,
	abilities: string[],
): boolean {
	return !dest.ability || abilities.includes(dest.ability);
}

/** 按 key 查找目的地并做门控判定；key 不存在时返回 false（不 throw）。 */
export function canSeeByKey(key: string, abilities: string[]): boolean {
	const dest = SETTINGS_NAV.find((d) => d.key === key);
	return dest ? canSee(dest, abilities) : false;
}
