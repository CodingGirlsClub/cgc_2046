"use client";

import { useParams } from "next/navigation";
import { OfferingDetailPage } from "@/components/offering-pages";

export default function Page() {
	const params = useParams<{ slug: string; id: string }>();
	return (
		<OfferingDetailPage
			slug={params?.slug ?? ""}
			id={params?.id ?? ""}
			kind="course"
		/>
	);
}
