import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

/**
 * E-3 #48 赞助 GraphQL 契约（对齐 backend sponsorship.ex/sponsorship_delivery.ex
 * graphql 段）。
 *
 * - createSponsorship(input)：意向提交（level: "event" | "workspace"；event 级
 *   传 eventId，workspace 级传 targetWorkspaceId）；pending 停住等审批。
 * - approveSponsorship(id) / rejectSponsorship(id, input{rejectionReason})：
 *   E-8 /approvals kind dispatch 复用。
 * - sponsorships(filter)：Owner 管理面列表（filter workspaceId/eventId）；
 *   deliveries 嵌套履约账本行。
 * - fulfillDelivery(id, input{proofNote})：账本逐项核销。
 */

export type SponsorshipLevel = "event" | "workspace";
export type SponsorshipStatus =
	| "pending"
	| "active"
	| "rejected"
	| "expired"
	| "ended";

/** 档位配置（sponsorship_tiers json 项） */
export interface SponsorshipTierConfig {
	id: string;
	name: string;
	/** 建议金额（元；null = 未设） */
	amountSuggestion: number | null;
	/** 权益项列表 */
	benefits: string[];
	/** 独占位标记（同一目标该档位仅允许一个 active） */
	exclusive: boolean;
}

/** 履约账本行（激活时从 tier.benefits 物化） */
export interface SponsorshipDeliveryItem {
	id: string;
	benefit: string;
	dueDate: string | null;
	fulfilledAt: string | null;
	proofNote: string | null;
	exclusive: boolean;
}

export interface SponsorshipItem {
	id: string;
	level: SponsorshipLevel;
	workspaceId: string;
	eventId: string | null;
	status: SponsorshipStatus;
	tierId: string | null;
	tierName: string | null;
	amount: number | null;
	companyName: string;
	contactEmail: string;
	contactPhone: string | null;
	approvalDeadline: string | null;
	startedAt: string | null;
	endedAt: string | null;
	rejectionReason: string | null;
	deliveries: SponsorshipDeliveryItem[];
}

export type SponsorshipMutationResult = MutationResult<SponsorshipItem>;

/* ---------------- Queries ---------------- */

export const LIST_EVENT_SPONSORSHIPS: TypedDocumentNode<
	{ sponsorships: { results: SponsorshipItem[] } },
	{ eventId: string; workspaceId: string }
> = gql`
	query ListEventSponsorships($eventId: ID!, $workspaceId: ID!) {
		sponsorships(
			filter: { eventId: { eq: $eventId }, workspaceId: { eq: $workspaceId } }
		) {
			results {
				id
				level
				workspaceId
				eventId
				status
				tierId
				tierName
				amount
				companyName
				contactEmail
				contactPhone
				approvalDeadline
				startedAt
				endedAt
				rejectionReason
				deliveries {
					id
					benefit
					dueDate
					fulfilledAt
					proofNote
					exclusive
				}
			}
		}
	}
`;

export const LIST_WORKSPACE_SPONSORSHIPS: TypedDocumentNode<
	{ sponsorships: { results: SponsorshipItem[] } },
	{ workspaceId: string }
> = gql`
	query ListWorkspaceSponsorships($workspaceId: ID!) {
		sponsorships(filter: { workspaceId: { eq: $workspaceId } }) {
			results {
				id
				level
				workspaceId
				eventId
				status
				tierId
				tierName
				amount
				companyName
				contactEmail
				contactPhone
				approvalDeadline
				startedAt
				endedAt
				rejectionReason
				deliveries {
					id
					benefit
					dueDate
					fulfilledAt
					proofNote
					exclusive
				}
			}
		}
	}
`;

/* ---------------- Mutations ---------------- */

export const CREATE_SPONSORSHIP: TypedDocumentNode<
	{ createSponsorship: SponsorshipMutationResult },
	{ input: Record<string, unknown> }
> = gql`
	mutation CreateSponsorship($input: CreateSponsorshipInput!) {
		createSponsorship(input: $input) {
			result {
				id
				level
				status
				tierName
			}
			errors {
				message
			}
		}
	}
`;

export const APPROVE_SPONSORSHIP: TypedDocumentNode<
	{ approveSponsorship: SponsorshipMutationResult },
	{ id: string }
> = gql`
	mutation ApproveSponsorship($id: ID!) {
		approveSponsorship(id: $id) {
			result {
				id
				status
			}
			errors {
				message
			}
		}
	}
`;

export const REJECT_SPONSORSHIP: TypedDocumentNode<
	{ rejectSponsorship: SponsorshipMutationResult },
	{ id: string; input: { rejectionReason?: string } }
> = gql`
	mutation RejectSponsorship($id: ID!, $input: RejectSponsorshipInput!) {
		rejectSponsorship(id: $id, input: $input) {
			result {
				id
				status
			}
			errors {
				message
			}
		}
	}
`;

export const FULFILL_DELIVERY: TypedDocumentNode<
	{ fulfillDelivery: MutationResult<SponsorshipDeliveryItem> },
	{ id: string; input: { proofNote: string } }
> = gql`
	mutation FulfillDelivery($id: ID!, $input: FulfillDeliveryInput!) {
		fulfillDelivery(id: $id, input: $input) {
			result {
				id
				fulfilledAt
				proofNote
			}
			errors {
				message
			}
		}
	}
`;
