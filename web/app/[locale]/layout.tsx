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
import {
	appendUserLocaleParam,
	stripLocalePrefix,
} from "@/i18n/user-locale";
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

/**
 * User.locale 一次性对齐（L0 决策 5 协商链：URL > User.locale > cookie > …）。
 *
 * proxy 无法读 DB（边缘运行时），此处服务端补齐：无 cgc_locale cookie 且带登录
 * token 时查 me.locale。无论与当前 locale 差异与否都 redirect 一次，目标带
 * `?_ul=<locale>` 一次性标记——proxy 检测该参数即固化 cgc_locale（Set-Cookie），
 * 之后本函数因 cookie 存在早退：
 * - 差异（F0）：对齐到目标 locale 前缀；_ul 让 proxy 注入 cookie 断开
 *   「middleware 按 Accept-Language 再弹回」的 307 死循环；
 * - 一致（F2b）：同路径带 _ul 一跳，换 cookie 永久收敛（否则每次导航都查 me）。
 * me 查询失败静默降级为正常渲染（1500ms 超时，不阻塞页面）。
 */
async function alignUserLocale(): Promise<void> {
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
			signal: AbortSignal.timeout(1500),
		});
		const json = (await res.json()) as { data?: { me?: { locale?: string | null } } };
		const userLocale = json?.data?.me?.locale;
		if (!userLocale || !hasLocale(routing.locales, userLocale)) return;

		// x-pathname 是重写前的用户可见路径（含 query；/en 前缀可能存在）
		const raw = (await headers()).get("x-pathname") ?? "/";
		const stripped = stripLocalePrefix(raw);
		const target =
			userLocale === "en" ? (stripped === "/" ? "/en" : `/en${stripped}`) : stripped;
		redirect(appendUserLocaleParam(target, userLocale));
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
