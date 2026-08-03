"use client";

import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useQuery } from "@apollo/client/react";
import { gql } from "@apollo/client";
import { CombinedGraphQLErrors } from "@apollo/client/errors";

/**
 * 根 layout 共享的登录态确认（#7）。
 *
 * 单例 `me` 查询挂在 ApolloWrapper 内的 AuthProvider，通过 context 分发
 * { authed, confirmed }，避免每个页面/组件各起一个 useAuthed → 各发一次 me 查询。
 * 未认证用户进任何受保护页只触发这一次必失败的 me 查询（而非每页一次）。
 *
 * 首帧 { authed: false, confirmed: false }：SSR 与 hydration 首帧一致，
 * confirmed 前调用方不得重定向（否则已登录用户被先跳 /login）。
 *
 * #13：网络错误（ServerError / 传输层失败）与服务端认证错误
 * （CombinedGraphQLErrors: "unauthorized"）必须区分——前者不踢已登录用户，
 * 保持上次 confirmed 状态并自动重试；后者照常判定未登录。
 */

export interface AuthedState {
	/** 当前登录态（confirmed=true 后为真实值；此前固定 false 用于首帧渲染） */
	authed: boolean;
	/** 是否已完成登录态确认（me 查询返回后为 true） */
	confirmed: boolean;
}

const ME_QUERY = gql`
  query Me { me { id } }
`;

interface MeQueryResult {
	me: { id: string } | null;
}

const AuthContext = createContext<AuthedState>({ authed: false, confirmed: false });

/**
 * 网络错误判定：非 CombinedGraphQLErrors 的 error 均视为传输层失败。
 * CombinedGraphQLErrors = 服务端明确答复（含 unauthorized）→ 不是网络错误。
 */
function isNetworkError(e: unknown): boolean {
	if (!e) return false;
	return !CombinedGraphQLErrors.is(e);
}

// ponytail: me 查询网络错误重试。指数退避 1s/2s/4s，最多 3 次。
// 首帧即失败时保持 confirmed:false（卡 LoadingState）比误踢 /login 安全。
const RETRY_DELAYS = [1000, 2000, 4000];

export function AuthProvider({ children }: { children: ReactNode }) {
	const { data, loading, error, refetch } = useQuery<MeQueryResult>(ME_QUERY, { errorPolicy: "all" });
	const [state, setState] = useState<AuthedState>({ authed: false, confirmed: false });
	const retryingRef = useRef(false);

	useEffect(() => {
		if (loading) return;

		// 网络错误：不翻 confirmed，保持上次登录态，触发重试。
		if (error && isNetworkError(error)) {
			if (retryingRef.current) return;
			retryingRef.current = true;
			let cancelled = false;
			let attempt = 0;
			const tryRetry = () => {
				if (cancelled) return;
				const delay = RETRY_DELAYS[attempt] ?? RETRY_DELAYS[RETRY_DELAYS.length - 1];
				setTimeout(() => {
					if (cancelled) return;
					refetch()
						.then(() => {
							retryingRef.current = false;
						})
						.catch(() => {
							attempt++;
							if (attempt < RETRY_DELAYS.length) {
								tryRetry();
							} else {
								// ponytail: 重试用尽，保持上次 state（confirmed 不翻），等用户刷新恢复
								retryingRef.current = false;
							}
						});
				}, delay);
			};
			tryRetry();
			return () => {
				cancelled = true;
			};
		}

		// 无 error（成功）或 CombinedGraphQLErrors（未登录）：据 data?.me 定登录态。
		setState({ authed: !!data?.me, confirmed: true });
	}, [data, loading, error, refetch]);

	return <AuthContext.Provider value={state}>{children}</AuthContext.Provider>;
}

export function useAuthed(): AuthedState {
	return useContext(AuthContext);
}