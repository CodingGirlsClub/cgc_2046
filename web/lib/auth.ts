import { client, getAuthToken, buildAuthHeaders } from "./apollo-client";

/**
 * 登录态工具（#61 A-2-FE）。
 *
 * token 约定：登录成功后将 token 写入名为 `cgc_token` 的 cookie。
 * 请求侧由 apollo-client.ts 的 authLink 自动读取并附加 `Authorization: Bearer`。
 *
 * ⚠️ 待与后端对齐（#60）：token 的交付方式有两种候选——
 *   A) signIn/signUp mutation 响应体返回 token，前端 document.cookie 写入（当前实现假设此路径）；
 *   B) 后端 Set-Cookie httpOnly（此时 JS 读不到，authLink 改为依赖同源 cookie 自动携带）。
 * 当前静态骨架按 A 实现；#60 落定后按后端 schema 微调。
 */

export const TOKEN_COOKIE = "cgc_token";

export function setAuthToken(token: string): void {
	if (typeof document === "undefined") return;
	document.cookie = `${TOKEN_COOKIE}=${encodeURIComponent(token)}; path=/; max-age=86400; samesite=lax`;
}

export function clearAuthToken(): void {
	if (typeof document === "undefined") return;
	document.cookie = `${TOKEN_COOKIE}=; path=/; max-age=0; samesite=lax`;
}

export function isAuthenticated(): boolean {
	return Boolean(getAuthToken());
}

/**
 * 登出清理：清 cgc_token cookie + 清 Apollo InMemoryCache。
 * 清缓存是换用户不串数据的关键——同一 SPA 会话内 logout→login 另一用户时，
 * 单例 cache 仍持有前一用户的 meWorkspaces/me/myPortfolio，cache-first 会读到旧数据。
 * 用 clearStore（不 refetch）：登出导航中无需重发活动查询。
 */
export async function clearSession(): Promise<void> {
	clearAuthToken();
	await client.clearStore();
}

export { getAuthToken, buildAuthHeaders };
