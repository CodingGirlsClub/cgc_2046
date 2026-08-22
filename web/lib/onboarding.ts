import { useEffect, useState } from "react";
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

/** 当前用户的 onboarding me 片段（id + 邀请拒绝时间戳）；未登录为 null */
export async function fetchOnboardingMe(): Promise<OnboardingMe | null> {
	const { data } = await client.query({ query: ME_ONBOARDING });
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
};

/**
 * onboarding 状态单 hook（模态/常驻卡/向导页三消费方共用）。
 * 合并 me 查询（id + 拒绝态）与 fetchMyMcpTokens()（连接信号）：
 * 任一未完 loading=true；任一失败 error 非 null 且派生字段归零（fail-closed）。
 * userId 就绪（me 解析成功）时一次性快照 KTD4 session 旗标——挂载时 userId 未知，
 * 推迟到此处读才能保住「每 session 每用户最多弹一次」的跨刷新/跨重挂载语义。
 */
export function useOnboardingState(): OnboardingState {
	const [state, setState] = useState<OnboardingState>(INITIAL_STATE);

	useEffect(() => {
		let cancelled = false;

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
				});
			})
			.catch((err: unknown) => {
				if (cancelled) return;
				setState({
					dismissed: false,
					hasActiveToken: false,
					connected: false,
					loading: false,
					error: err instanceof Error ? err : new Error(String(err)),
					userId: null,
					inviteShownThisSession: false,
				});
			});

		return () => {
			cancelled = true;
		};
	}, []);

	return state;
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
