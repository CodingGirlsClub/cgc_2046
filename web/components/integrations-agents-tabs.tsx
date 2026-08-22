"use client";

/**
 * 集成 - Agents 域 Tab 实例（Settings 子域之一，plan 016 模式）。
 *
 * 四个路由 tab：MCP（Token 管理）/ OpenClacky（接入引导）/
 * opencode / OMP（手动配置）。未来 IM 集成按同一模式新建
 * IntegrationsImTabs 实例（复用 SettingsTabs 渲染层）。
 *
 * 目的地单源：本组件定义 tabs 数组；侧栏「集成」分组与品牌下拉菜单
 * 各自引用相同 URL（workspace-shell / workspace-switcher-menu）。
 */
import SettingsTabs, { type SettingsTabDef } from "@/components/settings-tabs";

const AGENTS_TABS: SettingsTabDef[] = [
	{
		key: "agents-mcp",
		labelKey: "mcp",
		href: (slug) => `/w/${slug}/settings/integrations/agents/mcp`,
	},
	{
		key: "agents-openclacky",
		labelKey: "openclacky",
		href: (slug) => `/w/${slug}/settings/integrations/agents/openclacky`,
	},
	{
		key: "agents-opencode",
		labelKey: "opencode",
		href: (slug) => `/w/${slug}/settings/integrations/agents/opencode`,
	},
	{
		key: "agents-omp",
		labelKey: "omp",
		href: (slug) => `/w/${slug}/settings/integrations/agents/omp`,
	},
];

export default function IntegrationsAgentsTabs({
	slug,
	current,
	abilities,
}: {
	slug: string;
	/** 当前页对应 tab key；缺省 = 无选中 tab（区入口页） */
	current?: string;
	abilities: string[];
}) {
	return (
		<SettingsTabs
			slug={slug}
			tabs={AGENTS_TABS}
			current={current}
			abilities={abilities}
		/>
	);
}
