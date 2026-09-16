import type { Metadata } from "next";
import { pageAlternates } from "@/lib/seo";
import InitiativeDetail from "@/components/initiative-detail";

type PageProps = {
	params: Promise<{ locale: string; slug: string }>;
};

// #239 契约：公开可索引页各自声明 canonical/hreflang。客户端页面（原实现为
// "use client" 路由）无法导出 generateMetadata——主体抽出到
// components/initiative-detail.tsx，本文件只做 server wrapper。
export async function generateMetadata({
	params,
}: PageProps): Promise<Metadata> {
	const { locale, slug } = await params;
	return {
		alternates: pageAlternates(`/initiatives/${encodeURIComponent(slug)}`, locale),
	};
}

export default async function Page({ params }: PageProps) {
	const { slug } = await params;
	return <InitiativeDetail slug={slug} />;
}
