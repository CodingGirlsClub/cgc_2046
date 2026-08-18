import { client } from "./apollo-client";
import {
	ACCEPT_SPEAKER_INVITATION,
	CREATE_SPEAKER_INVITATION,
	DECLINE_SPEAKER_INVITATION,
	SPEAKER_INVITATION_CARD,
	SPEAKER_INVITATIONS_FOR_EVENT,
	type CreateSpeakerInvitationInput,
	type CreateSpeakerInvitationResult,
	type SpeakerInvitationActionResult,
	type SpeakerInvitationCard,
	type SpeakerInvitationItem,
} from "./graphql/speaker-invitation";

/**
 * E-4 #49 SpeakerInvitation 数据源（唯一真实路径：GraphQL）。
 *
 * - fetchSpeakerInvitations：Event 邀请列表（Owner/Admin；read policy 兜底）
 * - fetchSpeakerInvitationCard：公开卡片（无效/过期/已用 → null）
 * - createSpeakerInvitation：创建 + 一次性 plainToken（邀请链接原料）
 * - accept/declineSpeakerInvitation：着陆页决策（token 一次性）
 */

export async function fetchSpeakerInvitations(
	eventId: string,
): Promise<SpeakerInvitationItem[]> {
	const { data } = await client.query({
		query: SPEAKER_INVITATIONS_FOR_EVENT,
		variables: { eventId },
	});

	return data?.speakerInvitations ?? [];
}

export async function fetchSpeakerInvitationCard(
	token: string,
): Promise<SpeakerInvitationCard | null> {
	const { data } = await client.query({
		query: SPEAKER_INVITATION_CARD,
		variables: { token },
	});

	return data?.speakerInvitationCard ?? null;
}

export async function createSpeakerInvitation(
	input: CreateSpeakerInvitationInput,
): Promise<CreateSpeakerInvitationResult> {
	const { data } = await client.mutate({
		mutation: CREATE_SPEAKER_INVITATION,
		variables: { input },
	});

	return (
		data?.createSpeakerInvitation ??
		({ result: null, plainToken: null, errors: [{ message: "errors.noResponse" }] } as CreateSpeakerInvitationResult)
	);
}

export async function acceptSpeakerInvitation(
	token: string,
): Promise<SpeakerInvitationActionResult> {
	const { data } = await client.mutate({
		mutation: ACCEPT_SPEAKER_INVITATION,
		variables: { token },
	});

	return data?.acceptSpeakerInvitation ?? { result: null, errors: [{ message: "errors.noResponse" }] };
}

export async function declineSpeakerInvitation(
	token: string,
): Promise<SpeakerInvitationActionResult> {
	const { data } = await client.mutate({
		mutation: DECLINE_SPEAKER_INVITATION,
		variables: { token },
	});

	return data?.declineSpeakerInvitation ?? { result: null, errors: [{ message: "errors.noResponse" }] };
}
