import type { Metadata } from "next";
import { pageAlternates } from "@/lib/seo";
import InitiativeIndex from "@/components/initiative-index";

type PageProps = {
	params: Promise<{ locale: string }>;
};

export async function generateMetadata({
	params,
}: PageProps): Promise<Metadata> {
	const { locale } = await params;
	return {
		alternates: pageAlternates("/initiatives", locale),
	};
}

export default function Page() {
	return <InitiativeIndex />;
}
