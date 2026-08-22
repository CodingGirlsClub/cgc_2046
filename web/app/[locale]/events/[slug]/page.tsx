import type { Metadata } from "next";
import { pageAlternates } from "@/lib/seo";
import PublicOfferingDetailPage from "@/components/public-offering-detail";

type PageProps = {
	params: Promise<{ locale: string; slug: string }>;
};

export async function generateMetadata({
	params,
}: PageProps): Promise<Metadata> {
	const { locale, slug } = await params;
	return {
		alternates: pageAlternates(`/events/${encodeURIComponent(slug)}`, locale),
	};
}

export default function Page() {
	return <PublicOfferingDetailPage kind="event" />;
}
