import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { pageAlternates } from "@/lib/seo";
import VoicesPage from "./voices-page";

export const dynamic = "force-dynamic";

type PageProps = {
	params: Promise<{ locale: string }>;
	searchParams: Promise<Record<string, string | string[] | undefined>>;
};

/**
 * 金句墙独立公开页（R26）：陌生人无需登录即可读、赞、分享单句与整墙。
 *
 * - 单句分享链接 `?item=<quote_id>`（KTD4）：直达该句并抑制开场（R7）；
 * - 失效 item（已撤回/未授权/不存在）→ 失效视图（U4，HTTP 200 软 404 语义）；
 * - 回访不重播（R8）与 reduced-motion（R24）在客户端处理。
 */
export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "flashback.voices" });
	return {
		title: t("metaTitle"),
		description: t("metaDescription"),
		alternates: pageAlternates("/flashback/voices", locale),
	};
}

export default async function Page({ searchParams }: PageProps) {
	const params = await searchParams;
	const item = typeof params.item === "string" ? params.item : undefined;
	return <VoicesPage item={item} />;
}
