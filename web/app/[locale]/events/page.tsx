import type { Metadata } from "next";
import { pageAlternates } from "@/lib/seo";
import PublicOfferingsPage from "@/components/public-offerings";

type PageProps = {
	params: Promise<{ locale: string }>;
};

export async function generateMetadata({
	params,
}: PageProps): Promise<Metadata> {
	const { locale } = await params;
	return { alternates: pageAlternates("/events", locale) };
}

export default function Page() {
	return <PublicOfferingsPage kind="event" />;
}
