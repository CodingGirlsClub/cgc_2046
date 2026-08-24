import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
	ACCEPT_SPEAKER_INVITATION,
	CREATE_SPEAKER_INVITATION,
	DECLINE_SPEAKER_INVITATION,
	SPEAKER_INVITATIONS_FOR_EVENT,
	SPEAKER_INVITATION_CARD,
	SPEAKER_INVITATION_STATUS_LABEL,
	SPEAKER_INVITATION_STATUS_TONE,
} from "./speaker-invitation";

describe("speaker-invitation GraphQL 契约（对齐 speaker_invitation.ex + graphql_schema.ex 手写字段）", () => {
	it("speakerInvitations(eventId)：Event 邀请列表（Owner/Admin read policy 兜底）", () => {
		const doc = print(SPEAKER_INVITATIONS_FOR_EVENT);
		expect(doc).toContain("query SpeakerInvitationsForEvent($eventId: ID!)");
		expect(doc).toContain("speakerInvitations(eventId: $eventId)");
		expect(doc).toContain("speakerName");
		expect(doc).toContain("status");
		expect(doc).not.toContain("tokenHash");
	});

	it("speakerInvitationCard(token)：公开卡片只含状态/主题/时间 + Event 公开白名单 + viewerIsInviter", () => {
		const doc = print(SPEAKER_INVITATION_CARD);
		expect(doc).toContain("query SpeakerInvitationCard($token: String!)");
		expect(doc).toContain("speakerInvitationCard(token: $token)");
		expect(doc).toContain("topic");
		expect(doc).toContain("scheduledAt");
		expect(doc).toContain("viewerIsInviter");
		expect(doc).not.toContain("speakerEmail");
		expect(doc).not.toContain("tokenHash");
		expect(doc).not.toContain("invitedBy");
	});

	it("create 返回 plainToken（仅此一次）；accept/decline 输入 token", () => {
		const create = print(CREATE_SPEAKER_INVITATION);
		expect(create).toContain("mutation CreateSpeakerInvitation($input: CreateSpeakerInvitationInput!)");
		expect(create).toContain("plainToken");

		expect(print(ACCEPT_SPEAKER_INVITATION)).toContain(
			"acceptSpeakerInvitation(token: $token)",
		);
		expect(print(DECLINE_SPEAKER_INVITATION)).toContain(
			"declineSpeakerInvitation(token: $token)",
		);
	});
});

describe("speaker-invitation 展示词表", () => {
	it("状态词表覆盖全部枚举（invited/accepted/declined/completed）", () => {
		expect(Object.keys(SPEAKER_INVITATION_STATUS_LABEL).sort()).toEqual(
			["accepted", "completed", "declined", "invited"].sort(),
		);
		expect(Object.keys(SPEAKER_INVITATION_STATUS_TONE).sort()).toEqual(
			["accepted", "completed", "declined", "invited"].sort(),
		);
	});
});
