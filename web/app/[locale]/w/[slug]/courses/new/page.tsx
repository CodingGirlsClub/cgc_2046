"use client";

import { useParams } from "next/navigation";
import { OfferingNewPage } from "@/components/offering-pages";

export default function Page() {
	const params = useParams<{ slug: string }>();
	return <OfferingNewPage slug={params?.slug ?? ""} kind="course" />;
}
