"use client";

import { useEffect, useState } from "react";
import { useQuery } from "@apollo/client/react";
import { gql } from "@apollo/client";

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

/**
 * 登录态确认 hook（hydration-safe，#70 QA 修复）。
 *
 * 背景：token 在 httpOnly cookie 中（#60 路径 B），JS 不可读。
 * 通过 GraphQL `me` 查询判定登录态：返回 user → 已登录；报错 → 未登录。
 *
 * 行为：
 * - 首帧 { authed: false, confirmed: false }：SSR 与客户端 hydration 首帧一致
 *   （统一渲染未登录兜底壳），且未 confirmed 前调用方不得执行「未登录重定向」
 *   —— 否则已登录用户也会被先跳去 /login。
 * - me 查询返回后：
 *   - 已登录 → { authed: true, confirmed: true }（触发完整页渲染，已过 hydration
 *     阶段，不会 mismatch）；
 *   - 未登录 → { authed: false, confirmed: true }（调用方据此重定向 /login）。
 */
export function useAuthed(): AuthedState {
	const { data, loading } = useQuery<MeQueryResult>(ME_QUERY, {
		errorPolicy: "all",
	});
	const [state, setState] = useState<AuthedState>({
		authed: false,
		confirmed: false,
	});

	useEffect(() => {
		if (!loading) {
			queueMicrotask(() => {
				setState({ authed: !!data?.me, confirmed: true });
			});
		}
	}, [data, loading]);

	return state;
}
