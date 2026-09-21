import type { Metadata } from "next";
import RiverDawn from "./river-dawn";

export const metadata: Metadata = {
	title: "山河渐醒 · 闪念间交互原型",
	robots: { index: false, follow: false },
};

// Throwaway prototype: one approved direction, synthetic in-memory content only.
export default async function Page({ searchParams }: {
	searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
	const params = await searchParams;
	return <RiverDawn initialMode={params.view === "wishes" ? "wishes" : "voices"}
		initialId={typeof params.item === "string" ? params.item : undefined}
		initialCity={typeof params.city === "string" ? params.city : undefined}
		showIntro={params.intro !== "0" && params.entry !== "share" && !params.item} />;
}
