import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * LLM 算力网关 GraphQL 契约层（Plan 004 + Plan 008 Slice 1）。
 *
 * 约定：
 * - 所有 `*_mc` 字段与入参均为后端自定义 `BigInt` 标量；JSON 传输可表现为
 *   number 或十进制数字字符串，前端统一经 `lib/llm-credits.ts` 的 BigInt 工具处理。
 * - `createLlmPaymentOrder` 支持签约渠道 `wechat_native` / `alipay_qr`，
 *   订阅档位 `2900` / `9900` 分，永久包 `1000` / `5000` / `10000` / `50000` 分，
 *   工作台算力池充值 `10000..10000000` 分。
 */

/** GraphQL BigInt 标量在 JSON 中的运行时形态 */
export type BigIntScalar = number | string;

export type LlmOrderKind =
	| "llm_subscription"
	| "llm_credit_pack"
	| "llm_workspace_pool_topup";

export type LlmPaymentProvider = "wechat_native" | "alipay_qr";

export interface LlmCreditGrantItem {
	id: string;
	/** subscription | pack | workspace_grant | admin_gift */
	sourceType: string;
	initialMc: BigIntScalar;
	remainingMc: BigIntScalar;
	expiresAt?: string | null;
	/** active | exhausted | expired */
	status: string;
	insertedAt: string;
}

export interface LlmWalletSummary {
	walletId: string;
	cachedBalanceMc: BigIntScalar;
	heldMc: BigIntScalar;
	availableMc: BigIntScalar;
	maxConcurrentStreams: number;
	/** active | frozen */
	status: string;
	frozenReason?: string | null;
	remainingPercentage: number;
	activeGrants: LlmCreditGrantItem[];
}

export interface LlmUsageLogItem {
	id: string;
	sessionId?: string | null;
	logicalModel: string;
	billingMode: string;
	promptCacheHitTokens: BigIntScalar;
	promptCacheMissTokens: BigIntScalar;
	completionTokens: BigIntScalar;
	reasoningTokens: BigIntScalar;
	chargedMc: BigIntScalar;
	ttfbMs?: number | null;
	durationMs?: number | null;
	insertedAt: string;
}

export interface LlmWorkspaceGrantBatch {
	id: string;
	actorUserId: string;
	perMemberMc: BigIntScalar;
	memberCount: number;
	totalGrantedMc: BigIntScalar;
	consumedMc?: BigIntScalar;
	remainingMc?: BigIntScalar;
	expiredMc?: BigIntScalar;
	expiresAt?: string | null;
	idempotencyKey: string;
	insertedAt: string;
}

export interface LlmWorkspacePoolEntry {
	id: string;
	entryType: string;
	deltaMc: BigIntScalar;
	paymentOrderId?: string | null;
	workspaceBatchId?: string | null;
	actorUserId?: string | null;
	insertedAt: string;
}

export interface LlmWorkspacePoolSummary {
	workspaceId: string;
	creditPoolMc: BigIntScalar;
	distributedTotalMc?: BigIntScalar;
	distributedConsumedMc?: BigIntScalar;
	distributedRemainingMc?: BigIntScalar;
	updatedAt: string;
	recentBatches: LlmWorkspaceGrantBatch[];
	recentPoolEntries?: LlmWorkspacePoolEntry[] | null;
}

export interface LlmWorkspaceGrantResult {
	id: string;
	perMemberMc: BigIntScalar;
	memberCount: number;
	totalGrantedMc: BigIntScalar;
	idempotentReplay: boolean;
}

export interface LlmDailyChannelMetric {
	day: string;
	upstreamChannel: string;
	requestCount: number;
	abortedCount: number;
	waivedCount: number;
	cacheHitTokens: BigIntScalar;
	cacheMissTokens: BigIntScalar;
	completionTokens: BigIntScalar;
	totalChargedMc: BigIntScalar;
	totalUpstreamCostMc: BigIntScalar;
	grossMarginMc: BigIntScalar;
}

export interface LlmPaymentOrder {
	id: string;
	userId: string;
	workspaceId?: string | null;
	orderKind: string;
	provider: string;
	outTradeNo: string;
	amountCents: number;
	creditsMc: BigIntScalar;
	/** pending | paid | cancelled | expired */
	status: string;
	expiresAt?: string | null;
	paidAt?: string | null;
	insertedAt: string;
}

export interface LlmPaymentCheckoutOrder {
	id: string;
	status: string;
	amountCents: number;
	creditsMc: BigIntScalar;
	outTradeNo: string;
	paidAt?: string | null;
}

export interface LlmPaymentCheckout {
	order: LlmPaymentCheckoutOrder;
	credential: unknown;
}

export type AdminGrantUserLlmWallet = Pick<
	LlmWalletSummary,
	| "walletId"
	| "cachedBalanceMc"
	| "heldMc"
	| "availableMc"
	| "remainingPercentage"
	| "status"
>;

export type AdminRiskWalletSummary = Pick<
	LlmWalletSummary,
	"walletId" | "status" | "frozenReason" | "maxConcurrentStreams"
>;

/* ---------------- Queries ---------------- */

export const MY_LLM_WALLET: TypedDocumentNode<
	{ myLlmWallet: LlmWalletSummary | null },
	Record<string, never>
> = gql`
	query MyLlmWallet {
		myLlmWallet {
			walletId
			cachedBalanceMc
			heldMc
			availableMc
			maxConcurrentStreams
			status
			frozenReason
			remainingPercentage
			activeGrants {
				id
				sourceType
				initialMc
				remainingMc
				expiresAt
				status
				insertedAt
			}
		}
	}
`;

export const MY_LLM_USAGE_LOGS: TypedDocumentNode<
	{ myLlmUsageLogs: LlmUsageLogItem[] },
	{ limit?: number | null; before?: string | null }
> = gql`
	query MyLlmUsageLogs($limit: Int, $before: DateTime) {
		myLlmUsageLogs(limit: $limit, before: $before) {
			id
			sessionId
			logicalModel
			billingMode
			promptCacheHitTokens
			promptCacheMissTokens
			completionTokens
			reasoningTokens
			chargedMc
			ttfbMs
			durationMs
			insertedAt
		}
	}
`;

export const WORKSPACE_LLM_POOL: TypedDocumentNode<
	{ workspaceLlmPool: LlmWorkspacePoolSummary | null },
	{ workspaceId: string }
> = gql`
	query WorkspaceLlmPool($workspaceId: ID!) {
		workspaceLlmPool(workspaceId: $workspaceId) {
			workspaceId
			creditPoolMc
			distributedTotalMc
			distributedConsumedMc
			distributedRemainingMc
			updatedAt
			recentBatches {
				id
				actorUserId
				perMemberMc
				memberCount
				totalGrantedMc
				consumedMc
				remainingMc
				expiredMc
				expiresAt
				idempotencyKey
				insertedAt
			}
			recentPoolEntries {
				id
				entryType
				deltaMc
				paymentOrderId
				workspaceBatchId
				actorUserId
				insertedAt
			}
		}
	}
`;

export const ADMIN_LLM_USAGE_ANALYTICS: TypedDocumentNode<
	{ adminLlmUsageAnalytics: LlmDailyChannelMetric[] },
	{ days?: number | null }
> = gql`
	query AdminLlmUsageAnalytics($days: Int) {
		adminLlmUsageAnalytics(days: $days) {
			day
			upstreamChannel
			requestCount
			abortedCount
			waivedCount
			cacheHitTokens
			cacheMissTokens
			completionTokens
			totalChargedMc
			totalUpstreamCostMc
			grossMarginMc
		}
	}
`;

export const LLM_PAYMENT_ORDER: TypedDocumentNode<
	{ llmPaymentOrder: LlmPaymentOrder | null },
	{ id: string }
> = gql`
	query LlmPaymentOrder($id: ID!) {
		llmPaymentOrder(id: $id) {
			id
			userId
			workspaceId
			orderKind
			provider
			outTradeNo
			amountCents
			creditsMc
			status
			expiresAt
			paidAt
			insertedAt
		}
	}
`;

/* ---------------- Mutations ---------------- */

export const CREATE_LLM_PAYMENT_ORDER: TypedDocumentNode<
	{ createLlmPaymentOrder: LlmPaymentCheckout | null },
	{
		orderKind: LlmOrderKind;
		provider: LlmPaymentProvider;
		amountCents: number;
		workspaceId?: string | null;
		idempotencyKey: string;
	}
> = gql`
	mutation CreateLlmPaymentOrder(
		$orderKind: String!
		$provider: String!
		$amountCents: Int!
		$workspaceId: ID
		$idempotencyKey: String!
	) {
		createLlmPaymentOrder(
			orderKind: $orderKind
			provider: $provider
			amountCents: $amountCents
			workspaceId: $workspaceId
			idempotencyKey: $idempotencyKey
		) {
			order {
				id
				status
				amountCents
				creditsMc
				outTradeNo
				paidAt
			}
			credential
		}
	}
`;

export const DISTRIBUTE_WORKSPACE_LLM_CREDITS: TypedDocumentNode<
	{ distributeWorkspaceLlmCredits: LlmWorkspaceGrantResult | null },
	{
		workspaceId: string;
		perMemberMc: BigIntScalar;
		idempotencyKey: string;
		expiresAt?: string | null;
		targetUserIds?: string[] | null;
		targetRoles?: string[] | null;
	}
> = gql`
	mutation DistributeWorkspaceLlmCredits(
		$workspaceId: ID!
		$perMemberMc: BigInt!
		$idempotencyKey: String!
		$expiresAt: DateTime
		$targetUserIds: [ID!]
		$targetRoles: [String!]
	) {
		distributeWorkspaceLlmCredits(
			workspaceId: $workspaceId
			perMemberMc: $perMemberMc
			idempotencyKey: $idempotencyKey
			expiresAt: $expiresAt
			targetUserIds: $targetUserIds
			targetRoles: $targetRoles
		) {
			id
			perMemberMc
			memberCount
			totalGrantedMc
			idempotentReplay
		}
	}
`;

export const ADMIN_TOPUP_WORKSPACE_LLM_POOL: TypedDocumentNode<
	{ adminTopupWorkspaceLlmPool: LlmWorkspacePoolSummary | null },
	{ workspaceId: string; amountMc: BigIntScalar }
> = gql`
	mutation AdminTopupWorkspaceLlmPool($workspaceId: ID!, $amountMc: BigInt!) {
		adminTopupWorkspaceLlmPool(workspaceId: $workspaceId, amountMc: $amountMc) {
			workspaceId
			creditPoolMc
			updatedAt
			recentBatches {
				id
				actorUserId
				perMemberMc
				memberCount
				totalGrantedMc
				expiresAt
				idempotencyKey
				insertedAt
			}
			recentPoolEntries {
				id
				entryType
				deltaMc
				paymentOrderId
				workspaceBatchId
				actorUserId
				insertedAt
			}
		}
	}
`;

export const ADMIN_GRANT_USER_LLM_CREDITS: TypedDocumentNode<
	{ adminGrantUserLlmCredits: AdminGrantUserLlmWallet | null },
	{ userId: string; amountMc: BigIntScalar; expiresAt?: string | null }
> = gql`
	mutation AdminGrantUserLlmCredits(
		$userId: ID!
		$amountMc: BigInt!
		$expiresAt: DateTime
	) {
		adminGrantUserLlmCredits(
			userId: $userId
			amountMc: $amountMc
			expiresAt: $expiresAt
		) {
			walletId
			cachedBalanceMc
			heldMc
			availableMc
			remainingPercentage
			status
		}
	}
`;

export const ADMIN_UPDATE_USER_LLM_WALLET_STATUS: TypedDocumentNode<
	{ adminUpdateUserLlmWalletStatus: AdminRiskWalletSummary | null },
	{ userId: string; status: "active" | "frozen"; frozenReason?: string | null }
> = gql`
	mutation AdminUpdateUserLlmWalletStatus(
		$userId: ID!
		$status: String!
		$frozenReason: String
	) {
		adminUpdateUserLlmWalletStatus(
			userId: $userId
			status: $status
			frozenReason: $frozenReason
		) {
			walletId
			status
			frozenReason
			maxConcurrentStreams
		}
	}
`;

export const ADMIN_UPDATE_USER_LLM_CONCURRENCY: TypedDocumentNode<
	{ adminUpdateUserLlmConcurrency: AdminRiskWalletSummary | null },
	{ userId: string; maxConcurrentStreams: number }
> = gql`
	mutation AdminUpdateUserLlmConcurrency(
		$userId: ID!
		$maxConcurrentStreams: Int!
	) {
		adminUpdateUserLlmConcurrency(
			userId: $userId
			maxConcurrentStreams: $maxConcurrentStreams
		) {
			walletId
			status
			frozenReason
			maxConcurrentStreams
		}
	}
`;
