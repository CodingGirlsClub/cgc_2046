import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import SpeakerInvitePage from "./page";

const { useParams } = vi.hoisted(() => ({
	useParams: vi.fn(),
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { fetchSpeakerInvitationCard } = vi.hoisted(() => ({
	fetchSpeakerInvitationCard: vi.fn(),
}));
const { acceptSpeakerInvitation } = vi.hoisted(() => ({
	acceptSpeakerInvitation: vi.fn(),
}));
const { declineSpeakerInvitation } = vi.hoisted(() => ({
	declineSpeakerInvitation: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useParams,
	// ThemeProvider 依赖 usePathname 解析 workspace slug（ADR-0004）
	usePathname: () => "/events/demo-event/speaker-invite/tok_123",
}));
vi.mock("@/lib/auth-provider", () => ({ useAuthed }));
vi.mock("@/lib/speaker-invitations", () => ({
	fetchSpeakerInvitationCard,
	acceptSpeakerInvitation,
	declineSpeakerInvitation,
}));

const CARD = {
	status: "invited" as const,
	topic: "Elixir 实战",
	scheduledAt: "2026-08-20T10:00:00Z",
	viewerIsInviter: false,
	event: {
		id: "e1",
		slug: "demo-event",
		title: "CGC 分享会",
		description: "公开活动描述",
		status: "open",
	},
};

beforeEach(() => {
	vi.clearAllMocks();
	useParams.mockReturnValue({ slug: "demo-event", token: "tok_123" });
	useAuthed.mockReturnValue({ authed: false, confirmed: true, userId: null });
	fetchSpeakerInvitationCard.mockResolvedValue(CARD);
});

afterEach(cleanup);

describe("/events/[slug]/speaker-invite/[token] Speaker 着陆页", () => {
	it("渲染邀请卡片：Event 信息 + 主题/时间；未登录展示登录引导", async () => {
		render(<SpeakerInvitePage />);

		expect(await screen.findByText("CGC 分享会")).toBeInTheDocument();
		expect(screen.getByText(/公开活动描述/)).toBeInTheDocument();
		expect(screen.getByText(/Elixir 实战/)).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "登录后接受邀请" })).toBeInTheDocument();
		expect(screen.getByText(/注册一个全局账号/)).toBeInTheDocument();
	});

	it("无效/过期/已用 token（card 为 null）→ 统一错误态", async () => {
		fetchSpeakerInvitationCard.mockResolvedValue(null);
		render(<SpeakerInvitePage />);

		expect(await screen.findByText("邀请链接无效或已失效")).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "接受邀请" })).not.toBeInTheDocument();
	});

	it("已登录展示接受/婉拒按钮；接受成功展示终态", async () => {
		useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
		acceptSpeakerInvitation.mockResolvedValue({
			result: { id: "i1", status: "accepted" },
			errors: [],
		});
		render(<SpeakerInvitePage />);

		fireEvent.click(await screen.findByRole("button", { name: "接受邀请" }));

		expect(await screen.findByText("✓ 已接受邀请")).toBeInTheDocument();
		expect(acceptSpeakerInvitation).toHaveBeenCalledWith("tok_123");
	});

	it("婉拒成功展示已婉拒终态", async () => {
		useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
		declineSpeakerInvitation.mockResolvedValue({
			result: { id: "i1", status: "declined" },
			errors: [],
		});
		render(<SpeakerInvitePage />);

		fireEvent.click(await screen.findByRole("button", { name: "婉拒" }));

		expect(await screen.findByText("已婉拒邀请")).toBeInTheDocument();
		expect(declineSpeakerInvitation).toHaveBeenCalledWith("tok_123");
	});

	it("发出人打开自己的链接：不展示接受/婉拒，提示转给嘉宾", async () => {
		useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
		fetchSpeakerInvitationCard.mockResolvedValue({ ...CARD, viewerIsInviter: true });
		render(<SpeakerInvitePage />);

		expect(await screen.findByText("这是你发出的邀请")).toBeInTheDocument();
		expect(screen.getByText(/请把链接复制后转给嘉宾/)).toBeInTheDocument();
		expect(screen.queryByText("你被邀请为以下活动的分享嘉宾")).not.toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "接受邀请" })).not.toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "婉拒" })).not.toBeInTheDocument();
	});

	it("决策失败（如已用 token）展示错误消息", async () => {
		useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
		acceptSpeakerInvitation.mockResolvedValue({
			result: null,
			errors: [{ message: "invitation token is invalid, expired or already used" }],
		});
		render(<SpeakerInvitePage />);

		fireEvent.click(await screen.findByRole("button", { name: "接受邀请" }));

		expect(
			await screen.findByText("invitation token is invalid, expired or already used"),
		).toBeInTheDocument();
	});
});
