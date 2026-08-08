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

export interface NavDestination {
	key: string;
	label: string;
	href: (slug: string) => string;
	/** 需要的能力；缺省 = 恒显 */
	ability?: string;
	/** 所属分组（侧栏 Linear 分组用） */
	group: "personal" | "workspace";
}

export const SETTINGS_NAV: NavDestination[] = [
	{
		key: "members",
		label: "成员与角色",
		href: (s) => `/w/${s}/settings/members`,
		ability: "list_members",
		group: "workspace",
	},
	{
		key: "permissions",
		label: "权限映射",
		href: (s) => `/w/${s}/settings/permissions`,
		ability: "list_members",
		group: "workspace",
	},
	{
		key: "policy",
		label: "加入策略",
		href: (s) => `/w/${s}/settings/join-policy`,
		group: "workspace",
	},
	{
		key: "requests",
		label: "加入审批",
		href: (s) => `/w/${s}/settings/requests`,
		ability: "manage_members",
		group: "workspace",
	},
	{
		key: "invitations",
		label: "邀请管理",
		href: (s) => `/w/${s}/settings/invitations`,
		ability: "manage_members",
		group: "workspace",
	},
];

/** 某目的地对给定能力列表是否可见（无 ability = 恒显）。 */
export function canSee(dest: NavDestination, abilities: string[]): boolean {
	return !dest.ability || abilities.includes(dest.ability);
}
