import { useCallback, useEffect, useRef, useState } from "react";
import { client } from "./apollo-client";
import {
	ME_ONBOARDING,
	DISMISS_ONBOARDING_INVITATION,
} from "./graphql/onboarding";
import type { OnboardingMe } from "./graphql/onboarding";
import { fetchMyMcpTokens } from "./mcp";
import type { McpTokenItem } from "./mcp";

/**
 * 首公里 onboarding 数据层（plan 2026-08-22 first-mile-onboarding，U2）。
 *
 * - KTD2：邀请拒绝态持久化在服务端 User.onboardingInvitationDismissedAt（跨设备），
 *   经 me 查询读取、dismissOnboardingInvitation mutation 写入。
 * - KTD3：连接信号客户端派生，零新查询——token 复用 fetchMyMcpTokens()，
 *   hasActiveToken / connected 由 deriveOnboardingState 纯函数算出。
 * - KTD4：session 旗标 cgc:onboarding-invite-shown:{userId}（每 session 每用户最多
 *   自动弹一次；按 userId 命名空间——共享机器同 tab 换账号不继承已展示态），
 *   sessionStorage 访问全 try/catch 静默降级（仿 lib/order-credential.ts）。
 * - KTD5：useOnboardingState 的 loading/error 对消费方 fail-closed——
 *   消费方（模态/常驻卡/向导页）必须先判 `loading || error` 再读布尔字段。
 */

/* ---------------- 派生 ---------------- */

export interface DerivedOnboardingState {
	/** 已明确拒绝邀请（服务端时间戳非 null） */
	dismissed: boolean;
	/** 有 active 连接 token（revoked / idle_expired 视同未接入，per R1 回归成员规则） */
	hasActiveToken: boolean;
	/** 已发生首次 MCP 调用（任一 token lastUsedAt != null；R8 完成后卡消失） */
	connected: boolean;
}

export interface OnboardingState extends DerivedOnboardingState {
	/** 两源（me 查询 / token 列表）任一未完即为真 */
	loading: boolean;
	/** 两源任一失败为非 null（fail-closed：消费方见此态不渲染模态/卡） */
	error: Error | null;
	/** 当前登录用户 id（me 查询解析后非 null；loading/error/未登录为 null）——
	    KTD4 session 旗标的命名空间维度 */
	userId: string | null;
	/** 本 session 当前用户是否已展示过邀请模态（userId 就绪时一次性快照；
	    userId 缺失为 false = 当作未展示，fail toward showing 由消费方门控兜底） */
	inviteShownThisSession: boolean;
	/** 原始 token 列表（新→旧；loading/error 为 []）——向导页 hasTokenHistory
	    等存在性信号由此派生，消费方不得再行 fetch */
	tokens: McpTokenItem[];
}

/**
 * 派生 onboarding 三布尔（纯函数，可测）：
 * - hasActiveToken = 任一 token status === "active"（status 派生见 lib/mcp.ts mapMcpToken）
 * - connected = 任一 token lastUsedAt != null（历史首联达成即算，不看当前 status）
 * - dismissed = dismissedAt != null
 */
export function deriveOnboardingState(
	tokens: McpTokenItem[],
	dismissedAt: string | null,
): DerivedOnboardingState {
	return {
		dismissed: dismissedAt != null,
		hasActiveToken: tokens.some((t) => t.status === "active"),
		connected: tokens.some((t) => t.lastUsedAt != null),
	};
}

/* ---------------- fetchers ---------------- */

/** 当前用户的 onboarding me 片段（id + 邀请拒绝时间戳）；未登录为 null。
    network-only——拒绝/签发后的门控同 session 内必须读真值（ freshness 敏感读取
    惯例：lib/profile.ts、lib/admin.ts；与 fetchMyMcpTokens 对齐） */
export async function fetchOnboardingMe(): Promise<OnboardingMe | null> {
	const { data } = await client.query({
		query: ME_ONBOARDING,
		fetchPolicy: "network-only",
	});
	return data?.me ?? null;
}

/** 拒绝首公里接入邀请（幂等，仅本人；失败抛错由调用方内联处理） */
export async function dismissOnboardingInvitation(): Promise<void> {
	await client.mutate({ mutation: DISMISS_ONBOARDING_INVITATION });
}

/* ---------------- hook ---------------- */

const INITIAL_STATE: OnboardingState = {
	dismissed: false,
	hasActiveToken: false,
	connected: false,
	loading: true,
	error: null,
	userId: null,
	inviteShownThisSession: false,
	tokens: [],
};

/**
 * onboarding 状态单 hook（模态/常驻卡/向导页三消费方共用）。
 * 合并 me 查询（id + 拒绝态）与 fetchMyMcpTokens()（连接信号）：
 * 任一未完 loading=true；任一失败 error 非 null 且派生字段归零（fail-closed）。
 * userId 就绪（me 解析成功）时一次性快照 KTD4 session 旗标——挂载时 userId 未知，
 * 推迟到此处读才能保住「每 session 每用户最多弹一次」的跨刷新/跨重挂载语义。
 * tokens 原始列表一并暴露（向导页 hasTokenHistory 复用，不得二次 fetch）。
 * reload() 供消费方内联错误态的「重试」：nonce 递增触发两源重拉。
 * refreshSilently() 供等待首联态轮询（P2）：不置 loading（拉取期间旧数据保持
 * 展示、卡不闪烁）；静默轮次失败保留上次成功快照（瞬时网络错误不能经
 * fail-closed 把卡弄没），留待下一轮再试。
 */
export function useOnboardingState(): OnboardingState & {
	reload: () => void;
	refreshSilently: () => void;
} {
	const [state, setState] = useState<OnboardingState>(INITIAL_STATE);
	const [nonce, setNonce] = useState(0);
	// 本轮拉取是否为静默轮次（refreshSilently 置位、reload 复位，effect 内捕获快照）
	const silentRef = useRef(false);
	// 重试：loading 复位在事件回调里做（effect 体内同步 setState 违 react-hooks 规则），
	// nonce 递增触发两源重拉
	const reload = useCallback(() => {
		silentRef.current = false;
		setState((prev) => ({ ...prev, loading: true, error: null }));
		setNonce((n) => n + 1);
	}, []);
	// 静默刷新（P2）：只递增 nonce、不置 loading——旧数据保持展示，卡不闪烁
	const refreshSilently = useCallback(() => {
		silentRef.current = true;
		setNonce((n) => n + 1);
	}, []);

	useEffect(() => {
		let cancelled = false;
		const silent = silentRef.current;

		Promise.all([fetchOnboardingMe(), fetchMyMcpTokens()])
			.then(([me, tokens]) => {
				if (cancelled) return;
				const userId = me?.id ?? null;
				setState({
					...deriveOnboardingState(
						tokens,
						me?.onboardingInvitationDismissedAt ?? null,
					),
					loading: false,
					error: null,
					userId,
					inviteShownThisSession:
						userId != null && hasInviteShownThisSession(userId),
					tokens,
				});
			})
			.catch((err: unknown) => {
				if (cancelled) return;
				// 静默轮次失败：保留上次成功快照，留待下一轮（否则瞬时网络错误会经
				// fail-closed 把等待首联卡整个弄没）
				if (silent) return;
				setState({
					dismissed: false,
					hasActiveToken: false,
					connected: false,
					loading: false,
					error: err instanceof Error ? err : new Error(String(err)),
					userId: null,
					inviteShownThisSession: false,
					tokens: [],
				});
			});

		return () => {
			cancelled = true;
		};
	}, [nonce]);

	return { ...state, reload, refreshSilently };
}

/* ---------------- session 旗标（KTD4） ---------------- */

const INVITE_SHOWN_KEY = "cgc:onboarding-invite-shown";

/** 旗标按 userId 命名空间：共享机器同 tab 换账号（A→B）不继承已展示态 */
function inviteShownKey(userId: string): string {
	return `${INVITE_SHOWN_KEY}:${userId}`;
}

/**
 * 标记本 session 已展示过邀请模态（隐私模式写失败静默：最坏多弹一次，绝不 throw）。
 * userId 缺失时不写——无 user 维度的全局旗标会错误抑制同 tab 后续登录的账号。
 */
export function markInviteShown(userId: string | null): void {
	if (!userId) return;
	try {
		sessionStorage.setItem(inviteShownKey(userId), "1");
	} catch {
		// ignore private-mode write errors
	}
}

/**
 * 本 session 当前用户是否已展示过邀请模态（读失败静默落 false = 当作未展示）。
 * userId 未就绪同为 false（fail toward showing；是否真弹由消费方 eligibility 门控兜底）。
 */
export function hasInviteShownThisSession(userId: string | null): boolean {
	if (!userId) return false;
	try {
		return sessionStorage.getItem(inviteShownKey(userId)) === "1";
	} catch {
		return false;
	}
}
