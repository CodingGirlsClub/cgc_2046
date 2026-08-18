import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationError } from "./shared";

/**
 * E-4 #49 SpeakerInvitation GraphQL 契约（对齐 speaker_invitation.ex +
 * graphql_schema.ex 手写字段）。
 *
 * 关键约定：
 * - createSpeakerInvitation：Owner/Admin；plainToken 仅创建响应出现一次
 *   （库中只存 SHA256 哈希），邀请链接 = /events/{slug}/speaker-invite/{plainToken}；
 * - speakerInvitations(eventId)：Owner/Admin 可读（read policy 兜底）；
 * - speakerInvitationCard(token)：公开（无需登录）——只返回邀请主题/时间 +
 *   Event 公开白名单字段，不泄露其它邀请；无效/过期/已用 token 统一错误；
 * - accept/declineSpeakerInvitation(token)：登录后操作，token 一次性。
 */

/* ---------------- 类型 ---------------- */

export type SpeakerInvitationStatus = "invited" | "accepted" | "declined" | "completed";

export interface SpeakerInvitationItem {
	id: string;
	eventId: string;
	workspaceId: string;
	speakerName: string;
	speakerEmail: string | null;
	topic: string | null;
	scheduledAt: string | null;
	note: string | null;
	status: SpeakerInvitationStatus;
	acceptedAt: string | null;
	declinedAt: string | null;
	completedAt: string | null;
	expiresAt: string | null;
}

export type CreateSpeakerInvitationInput = {
	workspaceId: string;
	eventId: string;
	speakerName: string;
	speakerEmail?: string | null;
	topic?: string | null;
	scheduledAt?: string | null;
	note?: string | null;
};

export type CreateSpeakerInvitationResult = {
	result: SpeakerInvitationItem | null;
	plainToken: string | null;
	errors: MutationError[];
};

export type SpeakerInvitationActionResult = {
	result: SpeakerInvitationItem | null;
	errors: MutationError[];
};

/** 公开卡片（匿名可读：状态/主题/时间 + Event 公开白名单） */
export interface SpeakerInvitationCard {
	status: SpeakerInvitationStatus;
	topic: string | null;
	scheduledAt: string | null;
	event: {
		id: string;
		slug: string | null;
		title: string;
		description: string | null;
		status: string;
	};
}

/* ---------------- 展示词表（单源） ---------------- */

export const SPEAKER_INVITATION_STATUS_LABEL: Record<SpeakerInvitationStatus, string> = {
	invited: "labels.speakerStatus.invited",
	accepted: "labels.speakerStatus.accepted",
	declined: "labels.speakerStatus.declined",
	completed: "labels.speakerStatus.completed",
};

export const SPEAKER_INVITATION_STATUS_TONE: Record<
	SpeakerInvitationStatus,
	"neutral" | "positive" | "negative"
> = {
	invited: "neutral",
	accepted: "positive",
	declined: "negative",
	completed: "positive",
};

/* ---------------- Queries ---------------- */

export const SPEAKER_INVITATIONS_FOR_EVENT: TypedDocumentNode<
	{ speakerInvitations: SpeakerInvitationItem[] },
	{ eventId: string }
> = gql`
	query SpeakerInvitationsForEvent($eventId: ID!) {
		speakerInvitations(eventId: $eventId) {
			id
			eventId
			workspaceId
			speakerName
			speakerEmail
			topic
			scheduledAt
			note
			status
			acceptedAt
			declinedAt
			completedAt
			expiresAt
		}
	}
`;

export const SPEAKER_INVITATION_CARD: TypedDocumentNode<
	{ speakerInvitationCard: SpeakerInvitationCard | null },
	{ token: string }
> = gql`
	query SpeakerInvitationCard($token: String!) {
		speakerInvitationCard(token: $token) {
			status
			topic
			scheduledAt
			event {
				id
				slug
				title
				description
				status
			}
		}
	}
`;

/* ---------------- Mutations ---------------- */

export const CREATE_SPEAKER_INVITATION: TypedDocumentNode<
	{ createSpeakerInvitation: CreateSpeakerInvitationResult },
	{ input: CreateSpeakerInvitationInput }
> = gql`
	mutation CreateSpeakerInvitation($input: CreateSpeakerInvitationInput!) {
		createSpeakerInvitation(input: $input) {
			result {
				id
				eventId
				workspaceId
				speakerName
				speakerEmail
				topic
				scheduledAt
				note
				status
				acceptedAt
				declinedAt
				completedAt
				expiresAt
			}
			plainToken
			errors {
				message
				code
			}
		}
	}
`;

export const ACCEPT_SPEAKER_INVITATION: TypedDocumentNode<
	{ acceptSpeakerInvitation: SpeakerInvitationActionResult },
	{ token: string }
> = gql`
	mutation AcceptSpeakerInvitation($token: String!) {
		acceptSpeakerInvitation(token: $token) {
			result {
				id
				status
			}
			errors {
				message
				code
			}
		}
	}
`;

export const DECLINE_SPEAKER_INVITATION: TypedDocumentNode<
	{ declineSpeakerInvitation: SpeakerInvitationActionResult },
	{ token: string }
> = gql`
	mutation DeclineSpeakerInvitation($token: String!) {
		declineSpeakerInvitation(token: $token) {
			result {
				id
				status
			}
			errors {
				message
				code
			}
		}
	}
`;
