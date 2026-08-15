"use client";

/**
 * 按 slug 解析当前用户的工作区上下文（#70 QA P1 修复，#1 mock 首帧兜底已删除）。
 *
 * 背景：members / permissions / w/[slug] 三个页面原先用 MOCK_WORKSPACES 做首帧
 * 同步兜底，真实模式下首帧会渲染假工作区（「CGC 上海分社」等）再闪切真实数据。
 * 2026-08-02 决策：mock 双轨整体删除，未解析完成一律 loading 骨架，绝不渲染假数据。
 *
 * 本 hook 首先消费真实 `fetchMyWorkspaces` 成员列表；仅在列表 miss 且
 * `fetchCurrentProfile().isPlatformAdmin` 时按 slug 调用 `fetchWorkspaceBySlug`
 * fallback。普通用户未知 slug 不 fallback，保持不可访问态。
 * - 未解析完成（settled=false）→ ws=undefined、loading=true（首帧骨架）；
 * - 成员命中 → ws 为 meWorkspaces 中的真实工作区；
 * - 管理员 fallback 命中 → ws 为基础工作区字段，并标记 readOnlyVisitor；
 * - settled=true 且 ws=undefined 且 error=null → 该 slug 不存在或不可访问；
 *
 * 为避免 react-hooks/set-state-in-effect 同步 setState 警告，采用派生状态：
 * effect 只在异步 .then 中提交结果，首帧/loading 由 state.slug 与当前 slug 是否一致派生。
 */

import { useCallback, useEffect, useState } from "react";
import { fetchCurrentProfile } from "./profile";
import { fetchWorkspaceBySlug } from "./requests";
import { fetchMyWorkspaces, type WorkspaceListItem } from "./workspaces";

interface ResolvedState {
	/** 已解析结果的 slug（与当前 slug 不一致时视为过期） */
	slug: string;
	/** 解析出的工作区 */
	ws: WorkspaceListItem | undefined;
	/** 平台管理员非成员 fallback，进入业务页但保持只读 */
	readOnlyVisitor: boolean;
	/** 是否已完成解析（含失败） */
	settled: boolean;
	/** 网络/服务器错误；非空时页面渲染错误 + 重试出口 */
	error: Error | null;
}

export interface WorkspaceBySlugState {
	/** 当前用户可进入的工作区，或平台管理员只读审计工作区 */
	ws: WorkspaceListItem | undefined;
	/** 非成员 PlatformAdmin 的只读访客标记 */
	readOnlyVisitor: boolean;
	/** 是否仍在解析真实工作区 */
	loading: boolean;
	/** 网络/服务器错误（与「slug 不在我的列表」区分） */
	error: Error | null;
	/** 重新拉取（清 error 并再次解析） */
	retry: () => void;
}

export function useWorkspaceBySlug(slug: string): WorkspaceBySlugState {
	const [state, setState] = useState<ResolvedState>(() => ({
		slug,
		ws: undefined,
		readOnlyVisitor: false,
		settled: false,
		error: null,
	}));
	// retry 计数：递增触发 effect 重跑重新拉取。
	const [retryNonce, setRetryNonce] = useState(0);

	// slug 变化（或未解析）时保持 loading，不渲染过期/假数据
	const stale = state.slug !== slug;
	const ws = stale ? undefined : state.ws;
	const readOnlyVisitor = stale ? false : state.readOnlyVisitor;
	const error = stale ? null : state.error;
	const loading = stale || !state.settled;

	// 空 slug（WorkspaceShell：profile 页无工作区上下文时传 ""）不解析。
	const skip = slug === "";

	useEffect(() => {
		if (skip) return;
		let cancelled = false;

		fetchMyWorkspaces()
			.then(async (list) => {
				const memberWorkspace = list.find((workspace) => workspace.slug === slug);
				if (memberWorkspace) {
					return { ws: memberWorkspace, readOnlyVisitor: false };
				}

				const profile = await fetchCurrentProfile();
				if (!profile.isPlatformAdmin) {
					return { ws: undefined, readOnlyVisitor: false };
				}

				const workspace = await fetchWorkspaceBySlug(slug);
				if (!workspace) {
					return { ws: undefined, readOnlyVisitor: false };
				}

				return {
					ws: {
						...workspace,
						myRoleNames: [],
						myAbilities: [],
						myMembershipId: null,
						canAccess: false,
						memberCount: workspace.memberCount ?? undefined,
						readOnlyVisitor: true,
					},
					readOnlyVisitor: true,
				};
			})
			.then((resolved) => {
				if (cancelled) return;
				setState({
					slug,
					ws: resolved.ws,
					readOnlyVisitor: resolved.readOnlyVisitor,
					settled: true,
					error: null,
				});
			})
			.catch((e) => {
				if (cancelled) return;
				setState({
					slug,
					ws: undefined,
					readOnlyVisitor: false,
					settled: true,
					error: e instanceof Error ? e : new Error(String(e)),
				});
			});

		return () => {
			cancelled = true;
		};
	}, [skip, slug, retryNonce]);

	const retry = useCallback(() => {
		setState({
			slug,
			ws: undefined,
			readOnlyVisitor: false,
			settled: false,
			error: null,
		});
		setRetryNonce((n) => n + 1);
	}, [slug]);

	return skip
		? {
				ws: undefined,
				readOnlyVisitor: false,
				loading: false,
				error: null,
				retry,
			}
		: { ws, readOnlyVisitor, loading, error, retry };
}
