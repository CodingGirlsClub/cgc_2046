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
	// canonical/hreflang 不在 layout 兜底（#239）：layout 拿不到 pathname，站级
	// 兜底会让全部子页 canonical 自称首页（比不声明更糟）。公开可索引页各自在
	// generateMetadata 调 lib/seo.ts pageAlternates；私有页不声明，robots.ts 兜底。
	return {
		title: t("title"),
		description: t("description"),
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
