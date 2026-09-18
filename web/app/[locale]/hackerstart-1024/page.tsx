import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { localizedUrl, pageAlternates } from "@/lib/seo";
import HackerStart1024Page from "@/components/hackerstart-1024/campaign-page";

/**
 * /hackerstart-1024 路由（公开可索引，R1/#239 契约）。
 *
 * server wrapper 的存在理由："use client" 页面无法导出 generateMetadata——
 * canonical/hreflang 走 lib/seo.ts 的 pageAlternates（zh-CN 无前缀 / en 前缀），
 * 同时把分享 meta 交给微信抓取（R6：title / description 走 messages；分享卡图
 * 素材未就绪，见下方注释）。
 */
type PageProps = {
	params: Promise<{ locale: string }>;
};

export async function generateMetadata({
	params,
}: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "hackerstart1024.meta" });
	const title = t("title");
	const description = t("description");

	return {
		title,
		description,
		alternates: pageAlternates("/hackerstart-1024", locale),
		// 微信分享卡：og 三要素中 title/description 由头部 meta 提供，图片字段
		// **刻意省略**——分享卡图（十周年主视觉延展）素材待补，先不输出 images，
		// 避免微信抓到空图或站点默认图；素材到位后在此补 images。
		openGraph: {
			title,
			description,
			type: "website",
			url: localizedUrl("/hackerstart-1024", locale),
		},
	};
}

export default function Page() {
	return <HackerStart1024Page />;
}
