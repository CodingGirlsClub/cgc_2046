"use client";

/**
 * 按 slug 解析当前用户的工作区上下文（#70 QA P1 修复）。
 *
 * 背景：members / permissions / w/[slug] 三个页面原先直接用
 * MOCK_WORKSPACES.find(slug) 解析，真实模式下数据来自 API（fetchMyWorkspaces），
 * 不在 mock 内 → 「工作区不存在或不可访问」。
 *
 * 本 hook 让工作区上下文**优先使用真实数据**（fetchMyWorkspaces 内部按
 * USE_MOCK_WORKSPACES 切换 mock/真实），仅以 MOCK_WORKSPACES 做首帧同步兜底：
 * - 未解析完成（settled=false）且 mock 未命中 → ws=undefined、loading=true（首帧骨架）；
 * - 解析完成后 → ws 为 fetchMyWorkspaces 中按 slug 匹配的真实工作区；
 * - settled=true 且 ws=undefined → 该 slug 不存在或不可访问。
 *
 * 为避免 react-hooks/set-state-in-effect 同步 setState 警告，采用派生状态：
 * effect 只在异步 .then 中提交结果，首帧/loading 由 state.slug 与当前 slug 是否一致派生。
 */

import { useEffect, useState } from "react";
import {
  MOCK_WORKSPACES,
  fetchMyWorkspaces,
  type WorkspaceListItem,
} from "./workspaces";

interface ResolvedState {
  /** 已解析结果的 slug（与当前 slug 不一致时视为过期，回退 mock 首帧） */
  slug: string;
  /** 解析出的工作区（真实数据优先） */
  ws: WorkspaceListItem | undefined;
  /** 是否已从 fetchMyWorkspaces 完成解析（含失败） */
  settled: boolean;
}

export interface WorkspaceBySlugState {
  /** 当前用户可进入的工作区（按 slug 匹配真实数据；settled 后仍为 undefined = 不存在） */
  ws: WorkspaceListItem | undefined;
  /** 是否仍在解析真实工作区列表（此时 ws 未定，不应渲染「不存在」） */
  loading: boolean;
}

export function useWorkspaceBySlug(slug: string): WorkspaceBySlugState {
  const [state, setState] = useState<ResolvedState>(() => ({
    slug,
    ws: MOCK_WORKSPACES.find((w) => w.slug === slug),
    settled: false,
  }));

  // slug 变化（或未解析）时，以 mock 首帧兜底 + loading
  const stale = state.slug !== slug;
  const ws = stale ? MOCK_WORKSPACES.find((w) => w.slug === slug) : state.ws;
  const loading = stale || (!state.settled && ws === undefined);

  useEffect(() => {
    let cancelled = false;
    fetchMyWorkspaces()
      .then((list) => {
        if (cancelled) return;
        setState({ slug, ws: list.find((w) => w.slug === slug), settled: true });
      })
      .catch(() => {
        // 加载失败：保留 mock 兜底（若命中），否则视为不存在；不抛错打断页面
        if (cancelled) return;
        setState((prev) => ({ ...prev, slug, settled: true }));
      });
    return () => {
      cancelled = true;
    };
  }, [slug]);

  return { ws, loading };
}
