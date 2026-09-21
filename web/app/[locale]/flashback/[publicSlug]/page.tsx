import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { pageAlternates } from "@/lib/seo";
import ProfileView from "@/components/flashback/profile-view";
import "../flashback.css";

type PageProps = {
	params: Promise<{ locale: string; publicSlug: string }>;
};

/**
 * 实名支持档案页（U6/R31 credited 档）：游客可读、可索引（品牌素材出口，
 * R33）。slug 发布后不可变（ADR-0014）。
 */
export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale, publicSlug } = await params;
	const t = await getTranslations({ locale, namespace: "flashback.meta" });
	return {
		title: t("profileTitle"),
		description: t("homeDescription"),
		alternates: pageAlternates(`/flashback/${encodeURIComponent(publicSlug)}`, locale),
	};
}

export default async function Page({ params }: PageProps) {
	const { publicSlug } = await params;
	return <ProfileView slug={publicSlug} />;
}
