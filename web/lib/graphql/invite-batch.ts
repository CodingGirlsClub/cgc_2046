import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

/** InviteBatch 管理面字段（对齐 backend InviteBatch SDL）。 */
export type InviteBatchStatus = "active" | "disabled";

export interface InviteBatchItem {
	id: string;
	workspaceId: string;
	eventId: string | null;
	courseId: string | null;
	inviteCode: string;
	quota: number;
	remainingQuota: number;
	expiresAt: string | null;
	status: InviteBatchStatus;
	remark: string | null;
	insertedAt: string;
}

/**
 * workspaceId 是 Owner/Admin policy 从 global list filter 解析租户的必需字段。
 * eventId/courseId 二选一，由面板按当前 Offering kind 填充。
 */
export interface InviteBatchFilter {
	workspaceId: { eq: string };
	eventId?: { eq: string };
	courseId?: { eq: string };
}

export interface InviteBatchPage {
	results: InviteBatchItem[];
	endKeyset: string | null;
}

export interface ListInviteBatchesVariables {
	filter: InviteBatchFilter;
	first: number;
	after?: string | null;
}

export interface CreateInviteBatchInput {
	eventId?: string;
	courseId?: string;
	inviteCode: string;
	quota: number;
	expiresAt?: string | null;
	remark?: string | null;
}

export type InviteBatchMutationResult = MutationResult<InviteBatchItem>;

const INVITE_BATCH_FIELDS = `
	id
	workspaceId
	eventId
	courseId
	inviteCode
	quota
	remainingQuota
	expiresAt
	status
	remark
	insertedAt
`;

export const LIST_INVITE_BATCHES: TypedDocumentNode<
	{ inviteBatches: InviteBatchPage },
	ListInviteBatchesVariables
> = gql`
	query ListInviteBatches($filter: InviteBatchFilterInput, $first: Int!, $after: String) {
		inviteBatches(filter: $filter, first: $first, after: $after) {
			results {
				${INVITE_BATCH_FIELDS}
			}
			endKeyset
		}
	}
`;

export const CREATE_INVITE_BATCH: TypedDocumentNode<
	{ createInviteBatch: InviteBatchMutationResult },
	{ input: CreateInviteBatchInput }
> = gql`
	mutation CreateInviteBatch($input: CreateInviteBatchInput!) {
		createInviteBatch(input: $input) {
			result {
				${INVITE_BATCH_FIELDS}
			}
			errors {
				message
				code
			}
		}
	}
`;

export const DISABLE_INVITE_BATCH: TypedDocumentNode<
	{ disableInviteBatch: InviteBatchMutationResult },
	{ id: string }
> = gql`
	mutation DisableInviteBatch($id: ID!) {
		disableInviteBatch(id: $id) {
			result {
				${INVITE_BATCH_FIELDS}
			}
			errors {
				message
				code
			}
		}
	}
`;
