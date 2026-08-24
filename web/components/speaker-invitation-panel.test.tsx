import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import SpeakerInvitationPanel from "./speaker-invitation-panel";

const { fetchSpeakerInvitations, createSpeakerInvitation } = vi.hoisted(() => ({
	fetchSpeakerInvitations: vi.fn(),
	createSpeakerInvitation: vi.fn(),
}));
const { resendSpeakerInvitation } = vi.hoisted(() => ({
	resendSpeakerInvitation: vi.fn(),
}));
const { copyText } = vi.hoisted(() => ({ copyText: vi.fn() }));

vi.mock("@/lib/speaker-invitations", () => ({
	fetchSpeakerInvitations,
	createSpeakerInvitation,
	resendSpeakerInvitation,
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
	resendSpeakerInvitation.mockResolvedValue({
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
		expect(screen.queryByRole("link", { name: "邀请链接" })).not.toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: "复制" }));
		expect(copyText).toHaveBeenCalledWith(
			expect.stringContaining("/events/demo-event/speaker-invite/tok_new"),
		);
		expect(await screen.findByRole("button", { name: "已复制" })).toBeInTheDocument();
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

	it("invited 行展示重发按钮（有邮箱=重发）；点击后持新链接，成功提示不含送达承诺", async () => {
		resendSpeakerInvitation.mockResolvedValue({
			result: { ...ITEM },
			plainToken: "tok_resend",
			errors: [],
		});

		render(
			<SpeakerInvitationPanel eventId="e1" eventSlug="demo-event" workspaceId="w1" />,
		);

		await screen.findByText("张三");
		const resendBtn = await screen.findByRole("button", { name: "重发" });
		fireEvent.click(resendBtn);

		expect(await screen.findByText(/已重新生成邀请链接/)).toBeInTheDocument();
		expect(resendSpeakerInvitation).toHaveBeenCalledWith("i1");
		// 新 token 立即可复制（CopyInviteLink 出现在该行）
		expect(screen.getAllByText("邀请链接").length).toBeGreaterThan(0);
	});

	it("无邮箱 invited 行显示「重新生成链接」；终态行无重发入口", async () => {
		fetchSpeakerInvitations.mockResolvedValue([
			{ ...ITEM, id: "i-noemail", speakerEmail: null },
			{ ...ITEM, id: "i-done", status: "completed" as const },
		]);

		render(
			<SpeakerInvitationPanel eventId="e1" eventSlug="demo-event" workspaceId="w1" />,
		);

		await screen.findAllByText("张三");
		expect(screen.getByRole("button", { name: "重新生成链接" })).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "重发" })).not.toBeInTheDocument();
	});

	it("重发失败展示后端错误消息（如终态竞态）", async () => {
		resendSpeakerInvitation.mockResolvedValue({
			result: null,
			plainToken: null,
			errors: [
				{ message: "invitation is no longer pending (already accepted, declined or completed)" },
			],
		});

		render(
			<SpeakerInvitationPanel eventId="e1" eventSlug="demo-event" workspaceId="w1" />,
		);

		await screen.findByText("张三");
		fireEvent.click(await screen.findByRole("button", { name: "重发" }));

		expect(await screen.findByText(/no longer pending/)).toBeInTheDocument();
	});

	it("A 行请求进行中：B 行重发按钮同步禁用（与全局 guard 一致）", async () => {
		fetchSpeakerInvitations.mockResolvedValue([
			{ ...ITEM, id: "i-a" },
			{ ...ITEM, id: "i-b", speakerName: "李四" },
		]);

		const { promise, resolve } = Promise.withResolvers<unknown>();
		resendSpeakerInvitation.mockImplementation(() => promise);

		render(
			<SpeakerInvitationPanel eventId="e1" eventSlug="demo-event" workspaceId="w1" />,
		);

		await screen.findAllByText("张三");
		const btnA = screen.getAllByRole("button", { name: "重发" })[0];
		const btnB = screen.getAllByRole("button", { name: "重发" })[1];

		fireEvent.click(btnA);
		expect(btnA).toBeDisabled();
		expect(btnB).toBeDisabled();

		resolve({ result: { ...ITEM, id: "i-a" }, plainToken: "tok_a", errors: [] });
		await screen.findByText(/已重新生成邀请链接/);
		expect(btnB).toBeEnabled();
	});
});
