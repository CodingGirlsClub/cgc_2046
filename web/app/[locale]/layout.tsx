import type { Metadata } from "next";
import { connection } from "next/server";
import { notFound } from "next/navigation";
import { Inter, Geist_Mono } from "next/font/google";
import { NextIntlClientProvider, hasLocale } from "next-intl";
import { getTranslations } from "next-intl/server";
import ApolloWrapper from "@/app/apollo-provider";
import ThemeProvider from "@/lib/theme-provider";
import ThemeSync from "@/lib/theme-sync";
import { alignUserLocale } from "@/i18n/align-user-locale";
import { routing } from "@/i18n/routing";
import "../globals.css";

// Linear 设计系统默认字体（Inter）；mono 沿用 Geist Mono。en 复用 latin 子集，无需新字体。
const inter = Inter({
	variable: "--font-inter",
	subsets: ["latin"],
	display: "swap",
});

const geistMono = Geist_Mono({
	variable: "--font-geist-mono",
	subsets: ["latin"],
});

type LayoutProps = {
	children: React.ReactNode;
	params: Promise<{ locale: string }>;
};

export function generateStaticParams() {
	return routing.locales.map((locale) => ({ locale }));
}

export async function generateMetadata({
	params,
}: LayoutProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "metadata" });
	const base =
		process.env.NEXT_PUBLIC_WEB_BASE_URL ??
		process.env.NEXT_PUBLIC_SITE_URL ??
		"http://localhost:3000";
	// hreflang alternates（D3）：zh-CN 无前缀 / en /en 前缀；canonical 为当前 locale 页。
	// 具体路径由子页自行覆盖（此处仅兜底根路径）；en 的 zh-CN 备用指向无前缀 URL。
	const pathname = "/";
	const zhUrl = `${base}${pathname}`;
	const enUrl = `${base}/en${pathname}`;
	return {
		title: t("title"),
		description: t("description"),
		alternates: {
			canonical: locale === "en" ? enUrl : zhUrl,
			languages: {
				"zh-CN": zhUrl,
				en: enUrl,
			},
		},
	};
}

export default async function LocaleLayout({ children, params }: LayoutProps) {
	const { locale } = await params;
	if (!hasLocale(routing.locales, locale)) {
		notFound();
	}

	await connection();
	await alignUserLocale();

	return (
		<html
			lang={locale}
			className={`${inter.variable} ${geistMono.variable} h-full antialiased`}
		>
			<body className="min-h-full flex flex-col">
				<NextIntlClientProvider>
					<ThemeProvider>
						<ApolloWrapper>
							<ThemeSync />
							{children}
						</ApolloWrapper>
					</ThemeProvider>
				</NextIntlClientProvider>
			</body>
		</html>
	);
}
