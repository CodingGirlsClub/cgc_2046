import type { Metadata } from "next";
import { pageAlternates } from "@/lib/seo";
import HomePage from "./home-client";

/**
 * 首页 server 壳（#239）：client 实现在 home-client.tsx——"use client" 文件
 * 无法导出 generateMetadata，canonical/hreflang 必须由 server 组件声明。
 */
type PageProps = {
	params: Promise<{ locale: string }>;
};

export async function generateMetadata({
	params,
}: PageProps): Promise<Metadata> {
	const { locale } = await params;
	return { alternates: pageAlternates("/", locale) };
}

export default function Page() {
	return <HomePage />;
}
