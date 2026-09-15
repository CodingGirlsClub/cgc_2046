import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import { client } from "@/lib/apollo-client";
import type { MutationError } from "./shared";

/** Event 主理人（R12–R14）：Owner/Admin 增删；目标用户无需 Workspace 成员资格。 */
export type EventModerator = {
	id: string;
	workspaceId: string;
	eventId: string;
	userId: string;
	assignedBy: string | null;
	assignedAt: string;
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
		}
	}
`;

const ASSIGN_EVENT_MODERATOR: TypedDocumentNode<
	{ assignEventModerator: EventModeratorPayload },
	{ workspaceId: string; eventId: string; userId: string }
> = gql`
	mutation AssignEventModerator($workspaceId: ID!, $eventId: ID!, $userId: ID!) {
		assignEventModerator(workspaceId: $workspaceId, eventId: $eventId, userId: $userId) {
			result { id userId assignedAt }
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
