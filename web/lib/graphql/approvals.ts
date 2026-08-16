import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * E-8 #123 审批控制台数据源：kind-agnostic `myPendingApprovals` 消费 +
 * Enrollment 通过/拒绝 mutation。JoinRequest 动作复用 lib/graphql/join-request.ts。
 *
 * 行形状（D7）：kind / requester 摘要 / context 摘要 / approvalDeadline；
 * includeExpired=true 附带 expired 行（只读「已过期」区）。
 */

export interface PendingApprovalItem {
	id: string;
	kind: "enrollment" | "join_request" | "sponsorship" | string;
	workspaceId: string;
	userId: string;
	eventId?: string | null;
	courseId?: string | null;
	status: string;
	approvalDeadline?: string | null;
	expiredAt?: string | null;
	requesterName?: string | null;
	workspaceName?: string | null;
	contextTitle?: string | null;
	/** E-9 #123 expired 重提链接落点（workspace_slug 全 kind；event_slug 仅 sponsorship event 级） */
	workspaceSlug?: string | null;
	eventSlug?: string | null;
	/** E-3 #48 sponsorship 行（其他 kind 为 null） */
	level?: string | null;
	companyName?: string | null;
	contactEmail?: string | null;
	tierName?: string | null;
	amount?: number | null;
}

export const MY_PENDING_APPROVALS: TypedDocumentNode<
	{ myPendingApprovals: PendingApprovalItem[] },
	{ includeExpired?: boolean }
> = gql`
	query MyPendingApprovals($includeExpired: Boolean) {
		myPendingApprovals(includeExpired: $includeExpired) {
			id
			kind
			workspaceId
			userId
			eventId
			courseId
			status
			approvalDeadline
			expiredAt
			requesterName
			workspaceName
			contextTitle
			workspaceSlug
			eventSlug
			level
			companyName
			contactEmail
			tierName
			amount
		}
	}
`;

export const PENDING_APPROVALS_COUNT: TypedDocumentNode<
	{ pendingApprovalsCount: number },
	Record<string, never>
> = gql`
	query PendingApprovalsCount {
		pendingApprovalsCount
	}
`;


export interface EnrollmentApprovalResult {
	id: string;
	status: string;
}

export interface EnrollmentApprovalMutationPayload {
	result?: EnrollmentApprovalResult | null;
	errors?: { message: string }[] | null;
}

export const CONFIRM_ENROLLMENT: TypedDocumentNode<
	{ confirmEnrollment: EnrollmentApprovalMutationPayload },
	{ id: string }
> = gql`
	mutation ConfirmEnrollment($id: ID!) {
		confirmEnrollment(id: $id) {
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

export const REJECT_ENROLLMENT: TypedDocumentNode<
	{ rejectEnrollment: EnrollmentApprovalMutationPayload },
	{ id: string; input: { rejectionReason?: string } }
> = gql`
	mutation RejectEnrollment($id: ID!, $input: RejectEnrollmentInput!) {
		rejectEnrollment(id: $id, input: $input) {
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
