"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
	fetchMyMcpTokens,
	fetchMyOauthAuthorizations,
	revokeMcpToken,
	revokeOauthAuthorization,
	type McpTokenItem,
} from "./mcp";
import type { OauthAuthorization } from "./graphql/oauth-authorization";

/**
 * 用户级凭证管理状态（连接 token + OAuth 授权，U5/KTD3）：两处管理面共用——
 *
 * - 工作台集成页 `/w/[slug]/settings/integrations/agents/mcp`（含签发面）
 * - 用户级账号设置 `/settings/account/connections`（无工作台成员资格也可达）
 *
 * 两源同拉、错误一处收口（fail-closed：loading 或 error 时消费方不渲染列表）；
 * 撤销成功后本地即时回写（token 行改状态；授权行移除——web 撤销同时撤回同意行），
 * 宿主在下一次调用时才得到 401（拉模式，无推送通道）。
 *
 * 错误以**文案键**返回（`errors.*` 契约键或本模块的 fallback 键），消费方用
 * `useTranslations()` 翻译——本 hook 不依赖 i18n 命名空间。
 */

export interface McpCredentialsState {
	tokens: McpTokenItem[];
	authorizations: OauthAuthorization[];
	/** 两源任一未完成即 true */
	loading: boolean;
	/** 错误文案键（消费方 labelsT 翻译）；null = 无错误 */
	errorKey: string | null;
	/** 撤销进行中的 token id / clientId（禁用对应行的确认按钮） */
	revokingTokenId: string | null;
	revokingClientId: string | null;
	/** 重试（错误态「重试」按钮） */
	reload: () => void;
	/** 撤销连接 token；失败落 errorKey（不抛——调用方为组件内确认按钮） */
	revokeToken: (id: string) => Promise<void>;
	/** 撤销 OAuth 授权；失败落 errorKey */
	revokeAuthorization: (clientId: string) => Promise<void>;
	/** 签发成功回写（新 token 插到列表头部；签发面在消费方 McpTokenIssuePanel） */
	prependToken: (token: McpTokenItem) => void;
}

const LOAD_FAILED_KEY = "errors.loadMcpCredentialsFailed";
const REVOKE_TOKEN_FAILED_KEY = "errors.revokeMcpTokenFailed";
const REVOKE_AUTHORIZATION_FAILED_KEY = "errors.revokeOauthAuthorizationFailed";

export function useMcpCredentials({
	enabled = true,
}: { enabled?: boolean } = {}): McpCredentialsState {
	const [tokens, setTokens] = useState<McpTokenItem[]>([]);
	const [authorizations, setAuthorizations] = useState<OauthAuthorization[]>(
		[],
	);
	const [loading, setLoading] = useState(true);
	const [errorKey, setErrorKey] = useState<string | null>(null);
	const [revokingTokenId, setRevokingTokenId] = useState<string | null>(null);
	const [revokingClientId, setRevokingClientId] = useState<string | null>(null);
	const loadedRef = useRef(false);
	// 卸载后不落 setState（拉取与撤销回写都经它守卫）。
	// 每次 mount 复位：React StrictMode（dev）会 mount → cleanup → mount，
	// 只置位不复位会让首个挂载的拉取结果被永久丢弃（页面卡在 loading）。
	const unmountedRef = useRef(false);
	useEffect(() => {
		unmountedRef.current = false;
		return () => {
			unmountedRef.current = true;
		};
	}, []);

	const load = useCallback(async () => {
		setLoading(true);
		setErrorKey(null);
		try {
			const [tokenList, grantList] = await Promise.all([
				fetchMyMcpTokens(),
				fetchMyOauthAuthorizations(),
			]);
			if (unmountedRef.current) return;
			setTokens(tokenList);
			setAuthorizations(grantList);
		} catch (e) {
			if (unmountedRef.current) return;
			setErrorKey(e instanceof Error ? e.message : LOAD_FAILED_KEY);
		} finally {
			if (!unmountedRef.current) setLoading(false);
		}
	}, []);

	// 首次拉取：enabled（成员/登录态就绪）后一次性触发；后续刷新走 reload
	useEffect(() => {
		if (!enabled || loadedRef.current) return;
		loadedRef.current = true;
		void load();
	}, [enabled, load]);

	const reload = useCallback(() => {
		void load();
	}, [load]);

	const revokeToken = useCallback(async (id: string) => {
		setRevokingTokenId(id);
		try {
			const revoked = await revokeMcpToken(id);
			if (unmountedRef.current) return;
			setTokens((prev) => prev.map((item) => (item.id === id ? revoked : item)));
			setErrorKey(null);
		} catch (e) {
			if (unmountedRef.current) return;
			setErrorKey(e instanceof Error ? e.message : REVOKE_TOKEN_FAILED_KEY);
		} finally {
			if (!unmountedRef.current) setRevokingTokenId(null);
		}
	}, []);

	const revokeAuthorization = useCallback(async (clientId: string) => {
		setRevokingClientId(clientId);
		try {
			await revokeOauthAuthorization(clientId);
			if (unmountedRef.current) return;
			// web 撤销同时撤回同意行：该 client 已不再「已授权」，从列表移除
			//（宿主自撤销的审计行不经此路径，保留为「已撤销」行）
			setAuthorizations((prev) =>
				prev.filter((item) => item.clientId !== clientId),
			);
			setErrorKey(null);
		} catch (e) {
			if (unmountedRef.current) return;
			setErrorKey(
				e instanceof Error ? e.message : REVOKE_AUTHORIZATION_FAILED_KEY,
			);
		} finally {
			if (!unmountedRef.current) setRevokingClientId(null);
		}
	}, []);

	const prependToken = useCallback((token: McpTokenItem) => {
		setTokens((prev) => [token, ...prev]);
	}, []);

	return {
		tokens,
		authorizations,
		loading,
		errorKey,
		revokingTokenId,
		revokingClientId,
		reload,
		revokeToken,
		revokeAuthorization,
		prependToken,
	};
}
