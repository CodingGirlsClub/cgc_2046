"use client";

/**
 * Settings 子域通用 Tab 渲染层（面向未来多域架构）。
 *
 * 各 Settings 子域实例组件（members-tabs.tsx、未来 teams-tabs.tsx…）定义自己的
 * tab 列表（SettingsTabDef[]），传入本组件渲染统一的 ws-tabs 栏。
 * 门控：tab.ability 缺失 = 恒显；否则需 abilities 包含该能力。
 */
import Link from "next/link";
import { useTranslations } from "next-intl";
import { canSee } from "./workspace-nav";

export type SettingsTabDef = {
	key: string;
	/** workspaceNav messages key 名（渲染方 useTranslations("workspaceNav") 翻译） */
	labelKey: string;
	href: (slug: string) => string;
	/** 门控能力；缺省 = 恒显（不参与过滤） */
	ability?: string;
};

export default function SettingsTabs({
	slug,
	tabs,
	current,
	abilities,
}: {
	slug: string;
	tabs: SettingsTabDef[];
	current: string;
	abilities: string[];
}) {
	const navT = useTranslations("workspaceNav");
	return (
		<nav className="ws-tabs" aria-label={navT("tabsAria")}>
			{tabs.map((tab) => {
				if (!canSee(tab, abilities)) return null;
				const selected = tab.key === current;
				return (
					<Link
						key={tab.key}
						href={tab.href(slug)}
						className={`ws-tab ${selected ? "ws-tab--selected" : ""}`}
						aria-current={selected ? "page" : undefined}
					>
						{navT(tab.labelKey)}
					</Link>
				);
			})}
		</nav>
	);
}
