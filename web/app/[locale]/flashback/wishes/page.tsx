import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { pageAlternates } from "@/lib/seo";
import WishesPage from "./wishes-page";
import "../flashback.css";
import styles from "./wishes.module.css";

export const dynamic = "force-dynamic";

type PageProps = {
	params: Promise<{ locale: string }>;
	searchParams: Promise<Record<string, string | string[] | undefined>>;
};

/**
 * 许愿树独立公开页（wish2 U7/KTD8）：与 voices 平行的独立路由。
 *
 * - `?item=<wish_id>` 单条直达（复用批 1 同型：客户端 network-only 校验 +
 *   direct 状态随 prop 重置——失效渲染「这个愿望目前无法查看」软 404）；
 * - `?city=` 城市入 URL（voices↔wishes 互跳带城市，G10）；
 * - 开场记忆 localStorage 跨页共享（KTD8：双页切换不重播开场）。
 */
export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "flashback.wishes" });
	return {
		title: t("metaTitle"),
		description: t("metaDescription"),
		alternates: pageAlternates("/flashback/wishes", locale),
	};
}

export default async function Page({ searchParams }: PageProps) {
	const params = await searchParams;
	const item = typeof params.item === "string" ? params.item : undefined;
	const city = typeof params.city === "string" ? params.city : undefined;
	return <div className={styles.surface}><WishesPage item={item} initialCity={city} /></div>;
}
