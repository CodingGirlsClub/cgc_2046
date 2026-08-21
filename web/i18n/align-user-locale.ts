import { cookies, headers } from "next/headers";
import { redirect, unstable_rethrow } from "next/navigation";
import { hasLocale } from "next-intl";
import { LOCALE_COOKIE, routing } from "./routing";
import { appendUserLocaleParam, stripLocalePrefix } from "./user-locale";

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
 *
 * 全路径 best-effort（#283）：对齐属锦上添花，任何失败（配置缺失、token 失效、
 * me 超时）都按匿名降级渲染，绝不 500 整个 layout。
 *
 * 单独成文件（而非并入 user-locale.ts）：proxy 的 edge bundle import 了
 * user-locale.ts，此处的 next/headers 依赖不能混进去。
 */
export async function alignUserLocale(): Promise<void> {
	const cookieStore = await cookies();
	if (cookieStore.get(LOCALE_COOKIE)) return;
	const token = cookieStore.get("cgc_token")?.value;
	if (!token) return;

	// #283：曾在此 throw fail-fast（#213 防静默 localhost），但抛点在 try 外，
	// 生产运行时恰好缺该 env（Dockerfile ENV 不跨 stage、deploy.yml 无 env 段），
	// 所有带 token 无 locale cookie 的用户整页 500。构建期 fail-fast 已由
	// next.config.ts 承担；运行时缺失记日志后按匿名降级。
	const backendUrl = process.env.BACKEND_URL;
	if (!backendUrl) {
		console.error(
			"alignUserLocale: BACKEND_URL unset at runtime; skipping user locale alignment (#283)",
		);
		return;
	}
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
		// redirect() 以 Next 内部错误抛出，unstable_rethrow 原样上抛；其余
		// （token 失效、超时、非 JSON 响应等）静默降级为匿名渲染。
		// 曾用 `"digest" in error` 手判——会误放行任何带 digest 的非 redirect 错误（#283）。
		unstable_rethrow(error);
	}
}
