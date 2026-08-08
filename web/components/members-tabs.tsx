"use client";

/**
 * 成员权限域 Tab 实例（Settings 子域之一）。
 *
 * 5 个 tab 全放这里：成员与角色 / 权限映射 / 加入策略 / 加入审批 / 邀请管理，
 * 全部属于「Workspace 成员与权限管理」域，普通成员（无 list_members）不可见整组。
 * 门控：成员/权限 = list_members，审批/邀请 = manage_members，加入策略恒显。
 *
 * 目的地与门控单源：直接消费 SETTINGS_NAV 注册表（plan 016），侧栏/下拉菜单
 * 同源；未来新子域（如 teams）按同一模式新建实例组件，内部引用 settings-tabs 渲染层。
 */
import SettingsTabs from "@/components/settings-tabs";
import { SETTINGS_NAV } from "./workspace-nav";

export default function MembersTabs({
	slug,
	current,
	abilities,
}: {
	slug: string;
	current: string;
	abilities: string[];
}) {
	return (
		<SettingsTabs slug={slug} tabs={SETTINGS_NAV} current={current} abilities={abilities} />
	);
}
