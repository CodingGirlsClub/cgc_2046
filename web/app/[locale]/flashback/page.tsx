import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { pageAlternates } from "@/lib/seo";
import PublicHome from "@/components/flashback/public-home";
import "../flashback.css";

type PageProps = {
	params: Promise<{ locale: string }>;
};

/**
 * 闪念间公开首页（U6/R10）：游客可读、可索引（承接分享传播的回流流量）。
 */
export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "flashback.meta" });
	return {
		title: t("homeTitle"),
		description: t("homeDescription"),
		alternates: pageAlternates("/flashback", locale),
	};
}

export default function Page() {
	return <PublicHome />;
}
