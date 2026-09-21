import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { pageAlternates } from "@/lib/seo";
import EventDetail from "@/components/flashback/event-detail";
import "../../flashback.css";

type PageProps = {
	params: Promise<{ locale: string; key: string }>;
};

/**
 * 场次页（E 的 event 步）：/flashback/event/<场次 key>——长廊点格进入这一场。
 * 个人档案面（名册含姓氏隐名/寄出者全名）——整页 noindex。
 */
export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "flashback.meta" });
	return {
		title: t("capsuleTitle"),
		description: t("capsuleDescription"),
		robots: { index: false, follow: false },
		alternates: pageAlternates("/flashback/event", locale),
	};
}

export default async function Page({ params }: PageProps) {
	const { key } = await params;
	return <EventDetail eventKey={key} />;
}
