"use client";

/**
 * 工作台订单取数（两个缴费视图共用）：keyset 分页 + 请求代守卫。
 *
 * 从 offering-payments-panel 上提（原先工作区页没有分页，后端 default_limit
 * 静默截断）。筛选口径由调用方给：status 为空时用 defaultStatuses（空数组 =
 * 不过滤，工作区页「全部状态」），offering 维度二选一。
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { client } from "@/lib/apollo-client";
import { WORKSPACE_ORDERS, type Order } from "@/lib/graphql/orders";

/** 每页条数（两个视图一致；U7 keyset 口径） */
export const ORDERS_PAGE_SIZE = 20;

/** 默认视图：非终态 + 已退款 + 已没收（终态 cancelled/expired 经筛选查看） */
export const DEFAULT_VISIBLE_STATUSES: readonly string[] = [
	"pending",
	"paid",
	"refunding",
	"refund_failed",
	"refunded",
	"forfeited",
];

export interface UseWorkspaceOrdersOptions {
	workspaceId: string;
	/** false = 不取数（详情面板非 manage 时不渲染，也不该发请求） */
	enabled?: boolean;
	/** 状态精确筛选；空串/undefined = 走 defaultStatuses */
	status?: string;
	eventId?: string;
	courseId?: string;
	/** 空数组 = 不过滤（工作区页「全部状态」） */
	defaultStatuses?: readonly string[];
}

export interface WorkspaceOrdersState {
	orders: Order[];
	loadState: "loading" | "ok" | "error";
	hasMore: boolean;
	loadingMore: boolean;
	/** 重拉第一页（操作完成后刷新，保持当前筛选） */
	reload: () => Promise<void>;
	loadMore: () => Promise<void>;
}

export function useWorkspaceOrders({
	workspaceId,
	enabled = true,
	status,
	eventId,
	courseId,
	defaultStatuses = DEFAULT_VISIBLE_STATUSES,
}: UseWorkspaceOrdersOptions): WorkspaceOrdersState {
	const [orders, setOrders] = useState<Order[]>([]);
	const [loadState, setLoadState] = useState<"loading" | "ok" | "error">("loading");
	const [endKeyset, setEndKeyset] = useState<string | null>(null);
	const [hasMore, setHasMore] = useState(false);
	const [loadingMore, setLoadingMore] = useState(false);
	// 请求代守卫：筛选切换后的迟到响应不得覆写新筛选的结果
	const reqGen = useRef(0);
	// 数组按值入依赖：调用方传字面量也不会触发无限重载
	const statusKey = defaultStatuses.join(",");

	const buildFilter = useCallback(() => {
		const filter: Record<string, unknown> = {};

		if (status) {
			filter.status = { eq: status };
		} else if (statusKey) {
			filter.status = { in: statusKey.split(",") };
		}

		if (eventId) filter.eventId = { eq: eventId };
		if (courseId) filter.courseId = { eq: courseId };

		return filter;
	}, [status, eventId, courseId, statusKey]);

	const load = useCallback(async () => {
		if (!workspaceId || !enabled) return;

		const gen = ++reqGen.current;
		setLoadState("loading");

		try {
			const { data } = await client.query({
				query: WORKSPACE_ORDERS,
				variables: {
					workspaceId,
					filter: buildFilter(),
					first: ORDERS_PAGE_SIZE,
				},
			});

			if (gen !== reqGen.current) return;

			const page = data?.workspaceOrders;
			const results = page?.results ?? [];
			setOrders(results);
			setEndKeyset(page?.endKeyset ?? null);
			setHasMore(results.length === ORDERS_PAGE_SIZE);
			setLoadState("ok");
		} catch {
			if (gen === reqGen.current) setLoadState("error");
		}
	}, [workspaceId, enabled, buildFilter]);

	const loadMore = useCallback(async () => {
		if (loadingMore || !endKeyset) return;

		const gen = reqGen.current;
		setLoadingMore(true);

		try {
			const { data } = await client.query({
				query: WORKSPACE_ORDERS,
				variables: {
					workspaceId,
					filter: buildFilter(),
					first: ORDERS_PAGE_SIZE,
					after: endKeyset,
				},
			});

			// 期间发生了筛选切换（代已前进）→ 丢弃本页（不追加进新筛选）
			if (gen !== reqGen.current) return;

			const page = data?.workspaceOrders;
			const results = page?.results ?? [];
			setOrders((prev) => [...prev, ...results]);
			setEndKeyset(page?.endKeyset ?? null);
			setHasMore(results.length === ORDERS_PAGE_SIZE);
		} catch {
			if (gen === reqGen.current) setHasMore(false);
		} finally {
			setLoadingMore(false);
		}
	}, [workspaceId, buildFilter, endKeyset, loadingMore]);

	useEffect(() => {
		// microtask 包裹避开 effect 内同步 setState（react-hooks/set-state-in-effect），
		// 同 mine-view / capsule-view 先例
		Promise.resolve().then(() => void load());
	}, [load]);

	return { orders, loadState, hasMore, loadingMore, reload: load, loadMore };
}
