"use client";

import { useParams } from "next/navigation";
import { OfferingsListPage } from "@/components/offering-pages";

export default function Page() {
	const params = useParams<{ slug: string }>();
	return <OfferingsListPage slug={params?.slug ?? ""} kind="event" />;
}
