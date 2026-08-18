import type { Metadata } from "next";
import { connection } from "next/server";
import { cookies, headers } from "next/headers";
import { notFound, redirect } from "next/navigation";
import { Inter, Geist_Mono } from "next/font/google";
import { NextIntlClientProvider, hasLocale } from "next-intl";
import { getTranslations } from "next-intl/server";
import ApolloWrapper from "@/app/apollo-provider";
import ThemeProvider from "@/lib/theme-provider";
import ThemeSync from "@/lib/theme-sync";
import { LOCALE_COOKIE, routing } from "@/i18n/routing";
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
	return {
		title: t("title"),
		description: t("description"),
	};
}

/**
 * User.locale 一次性对齐（L0 决策 5 协商链：URL > User.locale > cookie > …）。
 *
 * proxy 无法读 DB（边缘运行时），此处服务端补齐：无 cgc_locale cookie 且带登录
 * token 时查 me.locale，与当前渲染 locale 不同则 redirect 到对应前缀 URL。
 * 对齐一次后 cookie 主导（切换器会写 cgc_locale），后续导航不再查询。
 * 查询失败静默降级为正常渲染，不阻塞页面。
 */
async function alignUserLocale(currentLocale: string): Promise<void> {
	const cookieStore = await cookies();
	if (cookieStore.get(LOCALE_COOKIE)) return;
	const token = cookieStore.get("cgc_token")?.value;
	if (!token) return;

	const backendUrl = process.env.BACKEND_URL ?? "http://localhost:4000";
	try {
		const res = await fetch(`${backendUrl}/api/graphql`, {
			method: "POST",
			headers: { "content-type": "application/json", cookie: `cgc_token=${token}` },
			body: JSON.stringify({ query: "{ me { locale } }" }),
			cache: "no-store",
		});
		const json = (await res.json()) as { data?: { me?: { locale?: string | null } } };
		const userLocale = json?.data?.me?.locale;
		if (!userLocale || userLocale === currentLocale) return;

		// x-pathname 是重写前的用户可见路径（/en 前缀可能存在），redirect 目标按目标 locale 规范化
		const raw = (await headers()).get("x-pathname") ?? "/";
		const stripped = raw === "/en" ? "/" : raw.replace(/^\/en(?=\/)/, "");
		redirect(userLocale === "en" ? (stripped === "/" ? "/en" : `/en${stripped}`) : stripped);
	} catch (error) {
		// redirect() 以 NEXT_REDIRECT 抛出，必须原样上抛；其余错误静默降级
		if (error && typeof error === "object" && "digest" in error) throw error;
	}
}

export default async function LocaleLayout({ children, params }: LayoutProps) {
	const { locale } = await params;
	if (!hasLocale(routing.locales, locale)) {
		notFound();
	}

	await connection();
	await alignUserLocale(locale);

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
