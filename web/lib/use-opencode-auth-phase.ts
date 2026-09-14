"use client";

import { useCallback, useEffect, useState } from "react";
import { fetchMyOauthAuthorizations, OPENCODE_CLIENT_ID } from "./mcp";

/**
 * opencode 接入第④步「授权连接」的阶段信号（U8，plan 2026-09-15 opencode-desktop-host）。
 *
 * 三态对应引导必须区分的情形：
 * - `idle`：平台上还没有这条授权记录——多半尚未触发授权（模型或学习空间命令未生效）；
 * - `pending`：已有同意行、宿主尚未换得凭证（U3 的 status 语义）——浏览器里的授权进行中；
 * - `active`：授权完成（活跃授权）——向导的完成判定由此驱动（第④步授权完成，R19）。
 *
 * 读取走 fetchMyOauthAuthorizations（network-only，与「最近使用」同一数据源），
 * 不改全局状态、不落库：调用方（向导 / opencode 原子页）各自消费结果。
 * 失败保留上一阶段——瞬时网络错误不得把「授权进行中」打回「尚未触发」。
 * 进入 active 即停表（终态不再轮询）；`enabled=false` 时不挂监听（非 opencode 分支不轮询）。
 */
export type OpencodeAuthPhase = "idle" | "pending" | "active";

export function useOpencodeAuthPhase(enabled: boolean): {
	phase: OpencodeAuthPhase;
	recheck: () => void;
} {
	const [phase, setPhase] = useState<OpencodeAuthPhase>("idle");
	const [nonce, setNonce] = useState(0);
	// 手动「检查状态」按钮的一次性重查（与轮询共用同一条读取路径）
	const recheck = useCallback(() => setNonce((n) => n + 1), []);
	const settled = phase === "active";

	useEffect(() => {
		if (!enabled || settled) return;
		let cancelled = false;
		const check = () => {
			fetchMyOauthAuthorizations()
				.then((grants) => {
					if (cancelled) return;
					// 只看 opencode 打包客户端的授权：其他客户端的活跃 grant 不代表
					// opencode 已连接（DCR 开启，任何 MCP 宿主都可注册）。
					const own = grants.filter((g) => g.clientId === OPENCODE_CLIENT_ID);
					if (own.some((g) => g.status === "active")) setPhase("active");
					else if (own.some((g) => g.status === "pending"))
						setPhase("pending");
					else setPhase("idle");
				})
				.catch(() => {
					// 保留上一阶段：等待态的引导文案不因一次读取失败而回退
				});
		};
		check();
		// 用户完成浏览器授权后切回本页（focus / 变可见）立即重查；30s interval 兜底
		// 分屏不切窗（回调内判 visible 才查）——与概览页等待首联态同款
		const onFocus = () => check();
		const onVisible = () => {
			if (document.visibilityState === "visible") check();
		};
		window.addEventListener("focus", onFocus);
		document.addEventListener("visibilitychange", onVisible);
		const timer = setInterval(() => {
			if (document.visibilityState === "visible") check();
		}, 30_000);
		return () => {
			cancelled = true;
			window.removeEventListener("focus", onFocus);
			document.removeEventListener("visibilitychange", onVisible);
			clearInterval(timer);
		};
	}, [enabled, settled, nonce]);

	return { phase, recheck };
}
