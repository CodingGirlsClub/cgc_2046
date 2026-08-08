import { client } from "./apollo-client";
import { gql } from "@apollo/client";

/**
 * 登录态工具（#61 A-2-FE）。
 *
 * token 由后端通过 httpOnly cookie 交付（#60 路径 B），JS 不可读。
 * 前端不再持有 token、不再读写 cgc_token cookie。
 * 登录态判定由 useAuthed hook 通过 GraphQL `me` 查询实现。
 */

/**
 * 登出清理：调 signOut mutation（后端清 httpOnly cookie）+ 清 Apollo InMemoryCache。
 * 清缓存是换用户不串数据的关键——同一 SPA 会话内 logout→login 另一用户时，
 * 单例 cache 仍持有前一用户的 meWorkspaces/me/myPortfolio，cache-first 会读到旧数据。
 * 用 clearStore（不 refetch）：登出导航中无需重发活动查询。
 *
 * 返回 `{ ok }`：signOut mutation 失败返回 `{ ok: false, error }`（本地缓存仍清），
 * 由 UI 决定是否导航——mutation 失败意味着 httpOnly cookie 仍有效，直接导航到
 * /login 会呈现「登出成功」的假象（共享/公共机器上下一用户可沿用前一身份）。
 */
export async function clearSession(): Promise<{ ok: boolean; error?: Error }> {
	try {
		await client.mutate({ mutation: SIGN_OUT_MUTATION });
		await client.clearStore();
		return { ok: true };
	} catch (e) {
		// 即便 signOut 失败也清本地缓存 —— 但上报失败让 UI 决定是否导航
		try {
			await client.clearStore();
		} catch {
			/* 忽略 */
		}
		return { ok: false, error: e instanceof Error ? e : new Error(String(e)) };
	}
}

const SIGN_OUT_MUTATION = gql`
	mutation SignOut {
		signOut
	}
`;
