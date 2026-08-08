"use client";

/**
 * 按 slug 解析当前用户的工作区上下文（#70 QA P1 修复，#1 mock 首帧兜底已删除）。
 *
 * 背景：members / permissions / w/[slug] 三个页面原先用 MOCK_WORKSPACES 做首帧
 * 同步兜底，真实模式下首帧会渲染假工作区（「CGC 上海分社」等）再闪切真实数据。
 * 2026-08-02 决策：mock 双轨整体删除，未解析完成一律 loading 骨架，绝不渲染假数据。
 *
 * 本 hook 只消费真实数据（fetchMyWorkspaces 唯一路径）：
 * - 未解析完成（settled=false）→ ws=undefined、loading=true（首帧骨架）；
 * - 解析完成后 → ws 为 fetchMyWorkspaces 中按 slug 匹配的真实工作区；
 * - settled=true 且 ws=undefined 且 error=null → 该 slug 不存在或不可访问；
 * - settled=true 且 error 非空 → 网络/服务器错误（与「不存在」区分，#017 Bug B：
 *   网络失败 ≠ 无权限，页面应给重试出口，避免误报「工作区不可访问」）。
 *
 * 为避免 react-hooks/set-state-in-effect 同步 setState 警告，采用派生状态：
 * effect 只在异步 .then 中提交结果，首帧/loading 由 state.slug 与当前 slug 是否一致派生。
 */

import { useCallback, useEffect, useState } from "react";
import { fetchMyWorkspaces, type WorkspaceListItem } from "./workspaces";

interface ResolvedState {
	/** 已解析结果的 slug（与当前 slug 不一致时视为过期，回到 loading） */
	slug: string;
	/** 解析出的工作区 */
	ws: WorkspaceListItem | undefined;
	/** 是否已从 fetchMyWorkspaces 完成解析（含失败） */
	settled: boolean;
	/** 网络/服务器错误；非空时页面渲染错误 + 重试出口（#017：网络失败 ≠ 无权限） */
	error: Error | null;
}

export interface WorkspaceBySlugState {
	/** 当前用户可进入的工作区（按 slug 匹配真实数据；settled 后仍为 undefined = 不存在） */
	ws: WorkspaceListItem | undefined;
	/** 是否仍在解析真实工作区列表（此时 ws 未定，不应渲染「不存在」） */
	loading: boolean;
	/** 网络/服务器错误（与「slug 不在我的列表」区分）；非空时页面应给重试出口 */
	error: Error | null;
	/** 重新拉取（清 error 并再次 fetchMyWorkspaces） */
	retry: () => void;
}

export function useWorkspaceBySlug(slug: string): WorkspaceBySlugState {
	const [state, setState] = useState<ResolvedState>(() => ({
		slug,
		ws: undefined,
		settled: false,
		error: null,
	}));
	// retry 计数：递增触发 effect 重跑重新拉取 —— 比把 fetch 提为回调更贴近既有
	// cancelled 清理语义（slug 变化/卸载时旧请求不落地）。
	const [retryNonce, setRetryNonce] = useState(0);

	// slug 变化（或未解析）时保持 loading，不渲染过期/假数据
	const stale = state.slug !== slug;
	const ws = stale ? undefined : state.ws;
	const error = stale ? null : state.error;
	const loading = stale || !state.settled;

	// 空 slug（⑤ WorkspaceShell：profile 页无工作区上下文时传 ""）不解析：
	// 恒返回 { ws: undefined, loading: false }，不发起 fetchMyWorkspaces。
	const skip = slug === "";

	useEffect(() => {
		if (skip) return;
		let cancelled = false;
		fetchMyWorkspaces()
			.then((list) => {
				if (cancelled) return;
				setState({
					slug,
					ws: list.find((w) => w.slug === slug),
					settled: true,
					error: null,
				});
			})
			.catch((e) => {
				if (cancelled) return;
				// 网络/服务器错误 ≠「不存在」：保留 error 供页面渲染重试出口（#017 Bug B）
				setState({
					slug,
					ws: undefined,
					settled: true,
					error: e instanceof Error ? e : new Error(String(e)),
				});
			});

		return () => {
			cancelled = true;
		};
	}, [skip, slug, retryNonce]);

	const retry = useCallback(() => {
		// 清 error + 回到未 settled（loading 骨架），再触发 effect 重新拉取
		setState({ slug, ws: undefined, settled: false, error: null });
		setRetryNonce((n) => n + 1);
	}, [slug]);

	return skip
		? { ws: undefined, loading: false, error: null, retry }
		: { ws, loading, error, retry };
}
