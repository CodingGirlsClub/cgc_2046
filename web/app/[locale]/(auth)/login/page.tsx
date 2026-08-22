import type { Metadata } from "next";
import { pageAlternates } from "@/lib/seo";
import AuthShell from "../auth-shell";

type PageProps = {
	params: Promise<{ locale: string }>;
};

export async function generateMetadata({
	params,
}: PageProps): Promise<Metadata> {
	const { locale } = await params;
	return { alternates: pageAlternates("/login", locale) };
}

export default function LoginPage() {
	return <AuthShell mode="login" />;
}
