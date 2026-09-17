import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { pageAlternates } from "@/lib/seo";
import CapsuleView from "@/components/flashback/capsule-view";
import "../flashback.css";

type PageProps = {
	params: Promise<{ locale: string }>;
};

/**
 * 时间胶囊（U5）：/flashback/capsule（token 或登录态；server wrapper +
 * client 主体，照 enter/page.tsx 范式）。个人档案面——整页 noindex。
 */
export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "flashback.meta" });
	return {
		title: t("capsuleTitle"),
		description: t("capsuleDescription"),
		robots: { index: false, follow: false },
		alternates: pageAlternates("/flashback/capsule", locale),
	};
}

export default function Page() {
	return <CapsuleView />;
}
