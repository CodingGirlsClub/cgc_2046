"use client";

import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";

/**
 * 视口内显影（第 7a 件）：IntersectionObserver 观测带 `data-develop-id` 的元素，
 * 进入视口即记入 `developed`（React 渲染出 --develop 类，动画在 CSS）并
 * unobserve（只播一次）；滚动进视口的新元素同样显影。
 * `enabled=false`（reduced-motion / 无 IntersectionObserver）时一律终态——
 * 前置态与动画都不出现，测试与老环境行为不变。
 *
 * 判据单源：场次页名册（event-roster）与长廊城市堆（corridor）共用。
 */
export function useDevelopOnView(enabled: boolean) {
	const [developed, setDeveloped] = useState<ReadonlySet<string>>(() => new Set());
	const observerRef = useRef<IntersectionObserver | null>(null);

	const ensureObserver = useCallback(() => {
		if (!enabled || typeof IntersectionObserver === "undefined") return null;
		if (!observerRef.current) {
			observerRef.current = new IntersectionObserver(
				(entries) => {
					const hits = entries.filter((entry) => entry.isIntersecting);
					if (hits.length === 0) return;
					const ids = hits
						.map((entry) => (entry.target as HTMLElement).dataset.developId ?? "")
						.filter((id) => id !== "");
					hits.forEach((entry) => observerRef.current?.unobserve(entry.target));
					setDeveloped((prev) => new Set([...prev, ...ids]));
				},
				{ rootMargin: "0px 0px -6% 0px", threshold: 0.1 },
			);
		}
		return observerRef.current;
	}, [enabled]);

	useEffect(() => () => observerRef.current?.disconnect(), []);

	const registerDevelop = useCallback(
		(node: HTMLElement | null) => {
			const observer = ensureObserver();
			if (node && observer) observer.observe(node);
		},
		[ensureObserver],
	);

	return { developed, registerDevelop };
}

/** 显影是否启用：非 reduced-motion 且环境有 IntersectionObserver（能力只读一次） */
export function useDevelopEnabled(reduced: boolean): boolean {
	const supported = useSyncExternalStore(
		() => () => {},
		() => typeof IntersectionObserver !== "undefined",
		() => false,
	);
	return supported && !reduced;
}

/** 显影类：启用时未进视口 → `--pending`；进视口 → `--develop`；不启用 → 无类（终态） */
export function developClass(base: string, active: boolean, developed: boolean): string {
	if (!active) return "";
	return developed ? ` ${base}--develop` : ` ${base}--pending`;
}
