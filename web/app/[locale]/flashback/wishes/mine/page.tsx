import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { pageAlternates } from "@/lib/seo";
import MyWishesView from "./mine-view";
import "../flashback.css";
import styles from "../wishes.module.css";

export const dynamic = "force-dynamic";

type PageProps = {
	params: Promise<{ locale: string }>;
};

/**
 * 我的愿望（M11）：登录即可、无历史档案也可用。个人面——整页 noindex。
 */
export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "flashback.myWishes" });
	return {
		title: t("metaTitle"),
		robots: { index: false, follow: false },
		alternates: pageAlternates("/flashback/wishes/mine", locale),
	};
}

export default function Page() {
	return (
		<div className={styles.surface}>
			<MyWishesView />
		</div>
	);
}
