import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { pageAlternates } from "@/lib/seo";
import Journey from "@/components/flashback/journey";
import "../flashback.css";

type PageProps = {
	params: Promise<{ locale: string }>;
};

/**
 * 闪念间首程 H5（U4）：/flashback/enter?token=…（server wrapper + client
 * 旅程，照 initiatives/[slug] 范式；动效样式在 ../flashback.css——KTD9）。
 * token 携带个人档案——整页 noindex，投放链接不进搜索索引。
 */
export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "flashback.meta" });
	return {
		title: t("enterTitle"),
		description: t("enterDescription"),
		robots: { index: false, follow: false },
		alternates: pageAlternates("/flashback", locale),
	};
}

export default function Page() {
	return <Journey />;
}
