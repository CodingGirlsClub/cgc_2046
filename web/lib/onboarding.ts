import { useEffect, useState } from "react";
import { client } from "./apollo-client";
import {
	ME_ONBOARDING,
	DISMISS_ONBOARDING_INVITATION,
} from "./graphql/onboarding";
import { fetchMyMcpTokens } from "./mcp";
import type { McpTokenItem } from "./mcp";

/**
 * 首公里 onboarding 数据层（plan 2026-08-22 first-mile-onboarding，U2）。
 *
 * - KTD2：邀请拒绝态持久化在服务端 User.onboardingInvitationDismissedAt（跨设备），
 *   经 me 查询读取、dismissOnboardingInvitation mutation 写入。
 * - KTD3：连接信号客户端派生，零新查询——token 复用 fetchMyMcpTokens()，
 *   hasActiveToken / connected 由 deriveOnboardingState 纯函数算出。
 * - KTD4：session 旗标 cgc:onboarding-invite-shown（每 session 最多自动弹一次），
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

/** 当前用户的邀请拒绝时间戳；未登录/未拒绝为 null */
export async function fetchOnboardingDismissal(): Promise<string | null> {
	const { data } = await client.query({ query: ME_ONBOARDING });
	return data?.me?.onboardingInvitationDismissedAt ?? null;
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
};

/**
 * onboarding 状态单 hook（模态/常驻卡/向导页三消费方共用）。
 * 合并 me 查询（拒绝态）与 fetchMyMcpTokens()（连接信号）：
 * 任一未完 loading=true；任一失败 error 非 null 且布尔归零（fail-closed）。
 */
export function useOnboardingState(): OnboardingState {
	const [state, setState] = useState<OnboardingState>(INITIAL_STATE);

	useEffect(() => {
		let cancelled = false;

		Promise.all([fetchOnboardingDismissal(), fetchMyMcpTokens()])
			.then(([dismissedAt, tokens]) => {
				if (cancelled) return;
				setState({
					...deriveOnboardingState(tokens, dismissedAt),
					loading: false,
					error: null,
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

/** 标记本 session 已展示过邀请模态（隐私模式写失败静默：最坏多弹一次，绝不 throw） */
export function markInviteShown(): void {
	try {
		sessionStorage.setItem(INVITE_SHOWN_KEY, "1");
	} catch {
		// ignore private-mode write errors
	}
}

/** 本 session 是否已展示过邀请模态（读失败静默落 false = 当作未展示） */
export function hasInviteShownThisSession(): boolean {
	try {
		return sessionStorage.getItem(INVITE_SHOWN_KEY) === "1";
	} catch {
		return false;
	}
}
