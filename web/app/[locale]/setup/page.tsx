import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { pageAlternates } from "@/lib/seo";
import SitePage from "@/components/site-page";
import { RuntimeSetupCards } from "@/components/runtime-setup-sections";

/**
 * /setup 环境准备落地页（公开可索引，供站内外教程引用）。
 *
 * 终端（macOS=Ghostty / Windows=Windows Terminal，附 WezTerm 附注）+
 * Herdr 安装与验证。内容卡与首公里向导、agents 原子页同一内容源
 * （@/components/runtime-setup-sections），本页只提供页面骨架，
 * 不得复制出第二处内容。
 */
type PageProps = {
	params: Promise<{ locale: string }>;
};

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "agentConnect" });
	return {
		title: t("setupTitle"),
		description: t("setupMetaDesc"),
		alternates: pageAlternates("/setup", locale),
	};
}

export default async function SetupPage({ params }: PageProps) {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "agentConnect" });
	return (
		<SitePage>
			<div className="mx-auto max-w-3xl px-4 py-10">
				<header>
					<h1 className="l-h1">{t("setupTitle")}</h1>
					<p className="mt-2 text-sm leading-6 text-ink-2">
						{t("setupSubtitle")}
					</p>
				</header>
				<div style={{ display: "grid", gap: 16, marginTop: 24 }}>
					<RuntimeSetupCards stepNos={["1.", "2.", "3."]} />
				</div>
			</div>
		</SitePage>
	);
}
