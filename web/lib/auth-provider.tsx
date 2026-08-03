"use client";

import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { useQuery } from "@apollo/client/react";
import { gql } from "@apollo/client";

/**
 * 根 layout 共享的登录态确认（#7）。
 *
 * 单例 `me` 查询挂在 ApolloWrapper 内的 AuthProvider，通过 context 分发
 * { authed, confirmed }，避免每个页面/组件各起一个 useAuthed → 各发一次 me 查询。
 * 未认证用户进任何受保护页只触发这一次必失败的 me 查询（而非每页一次）。
 *
 * 首帧 { authed: false, confirmed: false }：SSR 与 hydration 首帧一致，
 * confirmed 前调用方不得重定向（否则已登录用户被先跳 /login）。
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

export function AuthProvider({ children }: { children: ReactNode }) {
	const { data, loading } = useQuery<MeQueryResult>(ME_QUERY, { errorPolicy: "all" });
	const [state, setState] = useState<AuthedState>({ authed: false, confirmed: false });

	useEffect(() => {
		if (!loading) {
			queueMicrotask(() => {
				setState({ authed: !!data?.me, confirmed: true });
			});
		}
	}, [data, loading]);

	return <AuthContext.Provider value={state}>{children}</AuthContext.Provider>;
}

export function useAuthed(): AuthedState {
	return useContext(AuthContext);
}