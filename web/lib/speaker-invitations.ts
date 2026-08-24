import { client } from "./apollo-client";
import {
	ACCEPT_SPEAKER_INVITATION,
	CREATE_SPEAKER_INVITATION,
	DECLINE_SPEAKER_INVITATION,
	RESEND_SPEAKER_INVITATION,
	SPEAKER_INVITATIONS_FOR_EVENT,
	SPEAKER_INVITATION_CARD,
	type CreateSpeakerInvitationInput,
	type CreateSpeakerInvitationResult,
	type ResendSpeakerInvitationResult,
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
 * - resendSpeakerInvitation：重发/重新生成链接 + 新一次性 plainToken
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
		fetchPolicy: "network-only",
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
// 重发/重新生成链接：新 plainToken 仅此一次返回；有邮箱的同时后端异步发新邮件
export async function resendSpeakerInvitation(
	id: string,
): Promise<ResendSpeakerInvitationResult> {
	const { data } = await client.mutate({
		mutation: RESEND_SPEAKER_INVITATION,
		variables: { id },
	});

	return (
		data?.resendSpeakerInvitation ??
		({ result: null, plainToken: null, errors: [{ message: "errors.noResponse" }] } as ResendSpeakerInvitationResult)
	);
}
