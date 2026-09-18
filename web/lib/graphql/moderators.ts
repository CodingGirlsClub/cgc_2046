import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import { client } from "@/lib/apollo-client";
import type { MutationError } from "./shared";

/**
 * Event 主理人（R12–R14）：Owner/Admin 增删；被指派者须为本工作台成员
 * （#558 成员前提，非成员报 event_moderator_not_workspace_member）。
 * 指派输入为三锚点（#537）：邮箱 / CGC 编号 / 用户 ID 精确匹配，域层
 * resolve 后落 UUID。回显平铺字段走 displayName → memberNumber fallback 链。
 */
export type EventModerator = {
	id: string;
	workspaceId: string;
	eventId: string;
	userId: string;
	assignedBy: string | null;
	assignedAt: string;
	/** 主理人显示名（平铺投影，#537；未设置为 null） */
	userDisplayName: string | null;
	/** 主理人成员编号 CGC-XXXXXX（由 userId 确定性现算，恒非空） */
	userMemberNumber: string | null;
	/** 指派人显示名（assignedBy 为空时 null） */
	assignedByDisplayName: string | null;
	/** 指派人成员编号（assignedBy 为空时 null） */
	assignedByMemberNumber: string | null;
};

export type EventModeratorPayload = {
	result: EventModerator | null;
	errors: MutationError[];
};

const EVENT_MODERATORS: TypedDocumentNode<
	{ eventModerators: EventModerator[] },
	{ workspaceId: string; eventId: string }
> = gql`
	query EventModerators($workspaceId: ID!, $eventId: ID!) {
		eventModerators(workspaceId: $workspaceId, eventId: $eventId) {
			id
			workspaceId
			eventId
			userId
			assignedBy
			assignedAt
			userDisplayName
			userMemberNumber
			assignedByDisplayName
			assignedByMemberNumber
		}
	}
`;

const ASSIGN_EVENT_MODERATOR: TypedDocumentNode<
	{ assignEventModerator: EventModeratorPayload },
	{ workspaceId: string; eventId: string; userId: string }
> = gql`
	mutation AssignEventModerator($workspaceId: ID!, $eventId: ID!, $userId: ID!) {
		assignEventModerator(workspaceId: $workspaceId, eventId: $eventId, userId: $userId) {
			result {
				id
				userId
				assignedAt
				userDisplayName
				userMemberNumber
				assignedByDisplayName
				assignedByMemberNumber
			}
			errors { code message }
		}
	}
`;

const REMOVE_EVENT_MODERATOR: TypedDocumentNode<
	{ removeEventModerator: EventModeratorPayload },
	{ workspaceId: string; moderatorId: string }
> = gql`
	mutation RemoveEventModerator($workspaceId: ID!, $moderatorId: ID!) {
		removeEventModerator(workspaceId: $workspaceId, moderatorId: $moderatorId) {
			result { id }
			errors { code message }
		}
	}
`;

export async function fetchEventModerators(
	workspaceId: string,
	eventId: string,
): Promise<EventModerator[]> {
	const { data } = await client.query({
		query: EVENT_MODERATORS,
		variables: { workspaceId, eventId },
		fetchPolicy: "network-only",
	});
	return data?.eventModerators ?? [];
}

export async function assignEventModerator(
	workspaceId: string,
	eventId: string,
	userId: string,
): Promise<EventModeratorPayload> {
	const { data } = await client.mutate({
		mutation: ASSIGN_EVENT_MODERATOR,
		variables: { workspaceId, eventId, userId },
	});
	return data?.assignEventModerator ?? { result: null, errors: [] };
}

export async function removeEventModerator(
	workspaceId: string,
	moderatorId: string,
): Promise<EventModeratorPayload> {
	const { data } = await client.mutate({
		mutation: REMOVE_EVENT_MODERATOR,
		variables: { workspaceId, moderatorId },
	});
	return data?.removeEventModerator ?? { result: null, errors: [] };
}
