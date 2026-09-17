"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";

const REDUCED_QUERY = "(prefers-reduced-motion: reduce)";

/**
 * prefers-reduced-motion 单源 hook（U4 无障碍验收：reduced-motion 下
 * 跳过白光与显影、直达终态）。useSyncExternalStore 订阅系统设置变化；
 * SSR 快照恒 false（动效在场），客户端首帧即纠正。getSnapshot 返回布尔
 * 原始值（matchMedia 每次调用返回新实例，布尔比较不受影响）。
 */
export function usePrefersReducedMotion(): boolean {
	return useSyncExternalStore(
		(callback) => {
			const query = window.matchMedia(REDUCED_QUERY);
			query.addEventListener("change", callback);
			return () => query.removeEventListener("change", callback);
		},
		() => window.matchMedia(REDUCED_QUERY).matches,
		() => false,
	);
}

/**
 * 阶段标题焦点管理（U4 无障碍验收：阶段推进焦点落新标题）。
 * 返回 ref 回调——挂到每阶段标题（tabIndex=-1），阶段切换挂载即聚焦。
 */
export function useStageTitleFocus<T extends HTMLElement>(deps: readonly unknown[]) {
	const [node, setNode] = useState<T | null>(null);

	useEffect(() => {
		node?.focus();
		// eslint-disable-next-line react-hooks/exhaustive-deps -- 阶段键驱动
	}, [node, ...deps]);

	return setNode;
}

/** 一次性通知 ref（避免 effect 内同步 setState；reveal 的 revealed 事件用） */
export function useOnceCallback(action: () => void) {
	const fired = useRef(false);
	return () => {
		if (fired.current) return;
		fired.current = true;
		action();
	};
}
