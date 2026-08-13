import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import SpeakerInvitationPanel from "./speaker-invitation-panel";

const { fetchSpeakerInvitations } = vi.hoisted(() => ({
	fetchSpeakerInvitations: vi.fn(),
}));
const { createSpeakerInvitation } = vi.hoisted(() => ({
	createSpeakerInvitation: vi.fn(),
}));
const { copyText } = vi.hoisted(() => ({ copyText: vi.fn() }));

vi.mock("@/lib/speaker-invitations", () => ({
	fetchSpeakerInvitations,
	createSpeakerInvitation,
}));
vi.mock("@/lib/clipboard", () => ({ copyText }));

const ITEM = {
	id: "i1",
	eventId: "e1",
	workspaceId: "w1",
	speakerName: "张三",
	speakerEmail: "speaker@example.com",
	topic: "Elixir 实战",
	scheduledAt: "2026-08-20T10:00:00Z",
	note: null,
	status: "invited" as const,
	acceptedAt: null,
	declinedAt: null,
	completedAt: null,
	expiresAt: null,
};

beforeEach(() => {
	vi.clearAllMocks();
	fetchSpeakerInvitations.mockResolvedValue([ITEM]);
	createSpeakerInvitation.mockResolvedValue({
		result: null,
		plainToken: null,
		errors: [],
	});
	copyText.mockResolvedValue(true);
});

afterEach(cleanup);

describe("SpeakerInvitationPanel（Owner 入口：Event 详情页）", () => {
	it("渲染表单（姓名必填 + 邮箱/主题/时间/备注可选）与邀请列表状态徽章", async () => {
		render(
			<SpeakerInvitationPanel eventId="e1" eventSlug="demo-event" workspaceId="w1" />,
		);

		expect(screen.getByPlaceholderText("如：张三")).toBeInTheDocument();
		expect(screen.getByPlaceholderText("speaker@example.com")).toBeInTheDocument();

		expect(await screen.findByText("张三")).toBeInTheDocument();
		expect(screen.getByText("待接受")).toBeInTheDocument();
	});

	it("创建成功：调用 createSpeakerInvitation 并展示一次性邀请链接 + 复制按钮", async () => {
		createSpeakerInvitation.mockResolvedValue({
			result: { ...ITEM, id: "i2", speakerName: "李四" },
			plainToken: "tok_new",
			errors: [],
		});
		render(
			<SpeakerInvitationPanel eventId="e1" eventSlug="demo-event" workspaceId="w1" />,
		);

		await screen.findByText("张三");
		fireEvent.change(screen.getByPlaceholderText("如：张三"), {
			target: { value: "李四" },
		});
		fireEvent.click(screen.getByRole("button", { name: "创建邀请" }));

		expect(await screen.findByText("李四")).toBeInTheDocument();
		expect(createSpeakerInvitation).toHaveBeenCalledWith({
			workspaceId: "w1",
			eventId: "e1",
			speakerName: "李四",
			speakerEmail: null,
			topic: null,
			scheduledAt: null,
			note: null,
		});
		expect(screen.getByRole("link", { name: "邀请链接" })).toHaveAttribute(
			"href",
			"/events/demo-event/speaker-invite/tok_new",
		);
	});

	it("创建失败展示后端错误消息（如重复邀请）", async () => {
		createSpeakerInvitation.mockResolvedValue({
			result: null,
			plainToken: null,
			errors: [{ message: "an active invitation for this speaker already exists" }],
		});
		render(
			<SpeakerInvitationPanel eventId="e1" eventSlug="demo-event" workspaceId="w1" />,
		);

		await screen.findByText("张三");
		fireEvent.change(screen.getByPlaceholderText("如：张三"), {
			target: { value: "王五" },
		});
		fireEvent.click(screen.getByRole("button", { name: "创建邀请" }));

		expect(
			await screen.findByText("an active invitation for this speaker already exists"),
		).toBeInTheDocument();
	});
});
