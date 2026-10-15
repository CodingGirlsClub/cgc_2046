"use client";

/**
 * 课程页侧的配对（KTD3；R3、R4、R5；ADR-0022）：页面签发学习凭证 → 经本机连接交给 Host →
 * Host 向平台核实身份后弹窗，学员在本机确认。
 *
 * 连接由对话栏（U10）建立并传入；这里订阅 status 推进配对，并把最新 status 交还对话栏
 * （ompPresent、deviceName 等）。只产出状态，不带文案。
 * - 浏览器密钥按账号存进 localStorage：换账号即视为未配对。storage 不可用时静默降级——
 *   本次连接用内存里的密钥照常授权，刷新后要重新确认。
 * - 学习凭证明文只在 pair() 这一次调用的闭包里：不进 state、日志与 storage。
 * - 签发了凭证却没拿到「允许」（拒绝、Host 回 error、超时、连接中断），一律用登录态补撤销那一枚：
 *   Host 回 error 时没动它，拒绝时 Host 的自撤销只是尽力而为。
 */

import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { HostMessage, HostRequestFailure, HostSocket, HostStatus } from "@/lib/host-socket";
import { issueMcpToken, revokeMcpToken } from "@/lib/mcp";

/** Host 最晚约 80 秒给出结果（向平台核实 ≤10 秒 + 弹窗 60 秒 + 撤销 ≤10 秒），页面多等 10 秒 */
export const PAIR_TIMEOUT_MS = 90_000;
/** 每个连接首次 hello 时 Host 向平台核实凭证（≤10 秒） */
const HELLO_TIMEOUT_MS = 15_000;

/** checking：status 还没到，或正拿已存的密钥 hello */
export type PairingPhase = "checking" | "unpaired" | "confirming" | "denied" | "ready" | "error";

/**
 * error 的原因：busy / invalid_token / platform_unavailable / not_paired 是 Host 的 error.params.code
 * （含义见 cgc-host/AGENTS.md）；timeout / disconnected 是拿不到结果；token_limit 是签发撞上
 * 每人 10 枚的有效 token 上限；其余 Host 错误与签发失败归 failed。
 */
export type PairingErrorReason =
	| "busy"
	| "invalid_token"
	| "platform_unavailable"
	| "not_paired"
	| HostRequestFailure
	| "token_limit"
	| "failed";

export interface HostPairing {
	phase: PairingPhase;
	/** phase 为 error 时的原因，其余为 null */
	reason: PairingErrorReason | null;
	/** 最近一次收到的 status；连接未建立或 Host 还没推送时为 null */
	status: HostStatus | null;
	connect(): Promise<void>;
	/** 等待本机确认时取消：Host 关掉弹窗，按拒绝处理，页面回到未配对 */
	cancel(): void;
	/** 「已配对的电脑」撤销了本机这台之后调用：连接已授权就发 pair.forget，清掉本机密钥 */
	forget(): void;
}

/** 一次 connect() 的结局；null 表示回到由 status 推导的状态（已就绪，或取消后未配对） */
type Outcome = { phase: "confirming" | "denied" } | { phase: "error"; reason: PairingErrorReason };

const keyName = (userId: string) => `cgc:host-browser-key:${userId}`;

function readKey(userId: string): string | null {
	try {
		return localStorage.getItem(keyName(userId));
	} catch {
		return null;
	}
}

function storeKey(userId: string, browserKey: string) {
	try {
		localStorage.setItem(keyName(userId), browserKey);
	} catch {
		// 隐私模式等写不进去：本次连接已用内存里的密钥授权
	}
}

function forgetKey(userId: string) {
	try {
		localStorage.removeItem(keyName(userId));
	} catch {
		// ignore
	}
}

const PASSED_THROUGH: string[] = [
	"busy",
	"invalid_token",
	"platform_unavailable",
	"not_paired",
	"timeout",
	"disconnected",
];
const reasonOf = (code: unknown): PairingErrorReason =>
	PASSED_THROUGH.includes(code as string) ? (code as PairingErrorReason) : "failed";

async function pair(
	socket: HostSocket,
	status: HostStatus,
	userId: string,
	locale: string,
	run: { cancelled: boolean },
): Promise<Outcome | null> {
	// KTD3-5：Host 已为本账号配对（换了浏览器、清了站点数据）就不签发，只走本机确认换发浏览器密钥——
	// 否则每重新配对一次就多占一枚，很快占满每人 10 枚的上限
	let issued: { id: string; plainToken: string } | null = null;
	if (status.pairedUserId !== userId) {
		try {
			const { token, plainToken } = await issueMcpToken(status.deviceName, "LEARNING_HOST");
			issued = { id: token.id, plainToken };
		} catch (e) {
			const capped = e instanceof Error && e.message === "errors.mcp_token_limit_reached";
			return { phase: "error", reason: capped ? "token_limit" : "failed" };
		}
	}
	const revokeIssued = () => {
		// 补撤销失败（离线等）就算了：那一枚随 90 天闲置过期
		if (issued) revokeMcpToken(issued.id).catch(() => {});
	};
	if (run.cancelled) {
		revokeIssued();
		return null;
	}

	const reply = await socket
		.request("pair.request", issued ? { token: issued.plainToken, locale } : { locale }, {
			timeoutMs: PAIR_TIMEOUT_MS,
		})
		// 超时、连接中断与 Host 回 error 一样：拿不到结果
		.catch((e: Error): HostMessage => ({ method: "error", params: { code: e.message } }));

	if (reply.method === "pair.result" && reply.params?.allowed === true) {
		const browserKey = String(reply.params.browserKey);
		storeKey(userId, browserKey);
		// 用内存里的密钥 hello：storage 写不进去时本次连接也能用。结果以 Host 推来的 status 为准
		await socket.request("hello", { userId, browserKey }, { timeoutMs: HELLO_TIMEOUT_MS }).catch(() => {});
		return null;
	}

	revokeIssued();
	if (reply.method === "pair.result") return run.cancelled ? null : { phase: "denied" };
	// 超时时 Host 的弹窗可能还开着，让它关掉；连接已断时 send 不发
	socket.send("pair.cancel");
	return run.cancelled ? null : { phase: "error", reason: reasonOf(reply.params?.code) };
}

export function useHostPairing({
	socket,
	userId,
	locale,
}: {
	/** 对话栏（U10）建立的连接；没连上时为 null */
	socket: HostSocket | null;
	/** 当前登录账号 */
	userId: string;
	/** 本机确认弹窗的语言 */
	locale: string;
}): HostPairing {
	const subscribe = useCallback(
		(onChange: () => void) => (socket ? socket.on("status", onChange) : () => {}),
		[socket],
	);
	const status = useSyncExternalStore(
		subscribe,
		() => socket?.status ?? null,
		() => null,
	);

	/** 结局记在产生它的连接上：对话栏重连换了连接，上一条连接的 error(disconnected) 不再停留 */
	const [settled, setSettled] = useState<{ socket: HostSocket | null; outcome: Outcome | null }>({
		socket: null,
		outcome: null,
	});
	const outcome = settled.socket === socket ? settled.outcome : null;
	/** 已经有结果的 hello 发于哪个 status；还没结果时 phase 为 checking */
	const [helloSettledFor, setHelloSettledFor] = useState<HostStatus | null>(null);
	const helloSentFor = useRef<HostStatus | null>(null);
	const runRef = useRef<{ cancelled: boolean } | null>(null);

	const browserKey = status ? readKey(userId) : null;
	let phase: PairingPhase;
	if (!status) phase = "checking";
	// 换账号登录：这条连接为别的账号授权也不算
	else if (status.state === "ready" && status.pairedUserId === userId) phase = "ready";
	else if (outcome) phase = outcome.phase;
	else if (browserKey && helloSettledFor !== status) phase = "checking";
	else phase = "unpaired";

	// KTD3-1：收到 status 时，本账号存过浏览器密钥就 hello；回 unauthorized 即本机密钥已失效（Host 换发或清掉了），清掉
	useEffect(() => {
		if (phase !== "checking" || !socket || !status || !browserKey) return;
		if (helloSentFor.current === status) return;
		helloSentFor.current = status;
		socket
			.request("hello", { userId, browserKey }, { timeoutMs: HELLO_TIMEOUT_MS })
			.then((reply) => {
				if (reply.method === "error" && reply.params?.code === "unauthorized") forgetKey(userId);
			})
			// 超时、断开：密钥留着，下次连接再核实
			.catch(() => {})
			.finally(() => setHelloSettledFor(status));
	}, [phase, socket, status, browserKey, userId]);

	const connect = useCallback(async () => {
		if (!socket || !status || runRef.current) return;
		const run = { cancelled: false };
		runRef.current = run;
		setSettled({ socket, outcome: { phase: "confirming" } });
		try {
			const result = await pair(socket, status, userId, locale, run);
			setSettled({ socket, outcome: result });
		} finally {
			runRef.current = null;
		}
	}, [socket, status, userId, locale]);

	const cancel = useCallback(() => {
		if (!runRef.current) return;
		runRef.current.cancelled = true;
		socket?.send("pair.cancel");
	}, [socket]);

	const forget = useCallback(() => {
		// 未授权的连接发不了 pair.forget；Host 下次 hello 核实时遇 401 会自己清掉
		if (status?.state === "ready") socket?.send("pair.forget");
		forgetKey(userId);
		setSettled({ socket, outcome: null });
	}, [socket, status, userId]);

	return {
		phase,
		reason: outcome?.phase === "error" ? outcome.reason : null,
		status,
		connect,
		cancel,
		forget,
	};
}
