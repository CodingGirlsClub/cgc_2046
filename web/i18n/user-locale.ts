/**
 * User.locale 一次性固化参数（i18n Phase 1 评审修复 F0/F2b，方案 A）。
 *
 * 机制：`[locale]` 布局的 alignUserLocale redirect 目标附加 `?_ul=<locale>`；
 * proxy 检测到该参数后把 locale 固化进 cgc_locale cookie（响应 Set-Cookie +
 * 转发请求注入同名 cookie，使 next-intl 立即按该 locale 协商，不再经
 * Accept-Language 二次重定向），并从转发 URL 剥除参数。
 *
 * 解决两个缺陷：
 * - F0 死循环：User.locale=zh-CN + Accept-Language=en + 无 cookie 时
 *   「middleware 按 AL 弹 /en ↔ layout 按 me 弹 /」无限 307；
 * - F2b 不收敛：me.locale 与当前 locale 一致时每次导航都查 me 且永不写
 *   cookie——一致时也带 _ul redirect 一跳换永久收敛。
 *
 * 防伪造：_ul 值必须过 hasLocale 白名单；非法值仅剥参数，不写 cookie。
 */

/** 一次性固化参数名（下划线前缀表明内部机制参数，非公开 API） */
export const USER_LOCALE_PARAM = "_ul";

/**
 * 剥 /en 前缀（用户可见路径 → 内部无前缀路径；query 完整保留）。
 * zh-CN 是默认 locale（as-needed 无前缀），只有 en 需要剥。
 */
export function stripLocalePrefix(pathWithSearch: string): string {
	if (pathWithSearch === "/en") return "/";
	if (pathWithSearch.startsWith("/en?")) return `/${pathWithSearch.slice(3)}`;
	return pathWithSearch.replace(/^\/en(?=\/)/, "");
}

/** 追加 _ul 参数（已有 query 用 & 连接） */
export function appendUserLocaleParam(
	pathWithSearch: string,
	locale: string,
): string {
	return `${pathWithSearch}${pathWithSearch.includes("?") ? "&" : "?"}${USER_LOCALE_PARAM}=${locale}`;
}
