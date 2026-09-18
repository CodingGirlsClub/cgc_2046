import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import EventModeratorsCard from "./event-moderators-card";

const lib = vi.hoisted(() => ({
	fetchEventModerators: vi.fn(),
	assignEventModerator: vi.fn(),
	removeEventModerator: vi.fn(),
}));

vi.mock("@/lib/graphql/moderators", () => lib);

const clipboard = vi.hoisted(() => ({ copyText: vi.fn() }));
vi.mock("@/lib/clipboard", () => clipboard);

const ROW = {
	id: "mod-1",
	workspaceId: "ws-1",
	eventId: "evt-1",
	userId: "user-uuid-1",
	assignedBy: null,
	assignedAt: "2026-09-14T00:00:00Z",
	userDisplayName: null,
	userMemberNumber: "CGC-ABC123",
	assignedByDisplayName: null,
	assignedByMemberNumber: null,
};

beforeEach(() => {
	vi.clearAllMocks();
	lib.fetchEventModerators.mockResolvedValue([ROW]);
});

afterEach(cleanup);

describe("EventModeratorsCard", () => {
	it("渲染既有主理人列表", async () => {
		render(<EventModeratorsCard workspaceId="ws-1" eventId="evt-1" />);

		expect(await screen.findByText("user-uuid-1")).toBeInTheDocument();
		expect(screen.getByText("主理人")).toBeInTheDocument();
	});

	it("指派成功追加行并清空输入", async () => {
		lib.assignEventModerator.mockResolvedValue({
			result: { ...ROW, id: "mod-2", userId: "user-uuid-2" },
			errors: [],
		});

		render(<EventModeratorsCard workspaceId="ws-1" eventId="evt-1" />);
		await screen.findByText("user-uuid-1");

		fireEvent.change(screen.getByLabelText("邮箱 / CGC 编号 / 用户 ID"), {
			target: { value: "new-mod@cgc.example" },
		});
		fireEvent.click(screen.getByRole("button", { name: "指派主理人" }));

		expect(await screen.findByText("user-uuid-2")).toBeInTheDocument();
		expect(lib.assignEventModerator).toHaveBeenCalledWith(
			"ws-1",
			"evt-1",
			"new-mod@cgc.example",
		);
		expect(screen.getByLabelText("邮箱 / CGC 编号 / 用户 ID")).toHaveValue("");
	});

	it("指派失败按 code 出文案：未知 code 落兜底，成员前提 code 出引导句", async () => {
		// 未知 code：不透传英文原文，落通用兜底（translator 契约）
		lib.assignEventModerator.mockResolvedValueOnce({
			result: null,
			errors: [{ code: "not_found", message: "user not found" }],
		});

		render(<EventModeratorsCard workspaceId="ws-1" eventId="evt-1" />);
		await screen.findByText("user-uuid-1");

		fireEvent.change(screen.getByLabelText("邮箱 / CGC 编号 / 用户 ID"), {
			target: { value: "nobody" },
		});
		fireEvent.click(screen.getByRole("button", { name: "指派主理人" }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"主理人操作失败，请重试",
		);
		expect(screen.queryByText("nobody")).not.toBeInTheDocument();

		// #558 成员前提：已知 code 出引导文案
		lib.assignEventModerator.mockResolvedValueOnce({
			result: null,
			errors: [
				{
					code: "event_moderator_not_workspace_member",
					message: "the assignee must be a member of this workspace first",
				},
			],
		});

		fireEvent.change(screen.getByLabelText("邮箱 / CGC 编号 / 用户 ID"), {
			target: { value: "outsider-id" },
		});
		fireEvent.click(screen.getByRole("button", { name: "指派主理人" }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"该用户还不是本工作台成员，请先邀请加入再指派。",
		);
	});

	it("移除成功即时从列表消失", async () => {
		lib.removeEventModerator.mockResolvedValue({ result: null, errors: [] });

		render(<EventModeratorsCard workspaceId="ws-1" eventId="evt-1" />);
		await screen.findByText("user-uuid-1");

		fireEvent.click(screen.getByRole("button", { name: "移除" }));

		await waitFor(() =>
			expect(screen.queryByText("user-uuid-1")).not.toBeInTheDocument(),
		);
		expect(lib.removeEventModerator).toHaveBeenCalledWith("ws-1", "mod-1");
	});

	it("U9：有 slug → 复制核销页链接（绝对 URL + 已复制反馈）", async () => {
		clipboard.copyText.mockResolvedValue(true);

		render(
			<EventModeratorsCard
				workspaceId="ws-1"
				eventId="evt-1"
				workspaceSlug="cgc-academy"
			/>,
		);
		await screen.findByText("user-uuid-1");

		fireEvent.click(screen.getByTestId("copy-check-in-link"));

		await waitFor(() =>
			expect(clipboard.copyText).toHaveBeenCalledWith(
				`${window.location.origin}/w/cgc-academy/events/evt-1/check-in`,
			),
		);
		expect(await screen.findByText("已复制")).toBeInTheDocument();
	});

	it("U9：复制失败 → 就地给出可手动复制的链接（不静默失败）", async () => {
		clipboard.copyText.mockResolvedValue(false);

		render(
			<EventModeratorsCard
				workspaceId="ws-1"
				eventId="evt-1"
				workspaceSlug="cgc-academy"
			/>,
		);
		await screen.findByText("user-uuid-1");

		fireEvent.click(screen.getByTestId("copy-check-in-link"));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"/w/cgc-academy/events/evt-1/check-in",
		);
	});

	it("U9：en locale 复制链接带 /en 前缀（localePrefix as-needed）", async () => {
		clipboard.copyText.mockResolvedValue(true);

		render(
			<EventModeratorsCard
				workspaceId="ws-1"
				eventId="evt-1"
				workspaceSlug="cgc-academy"
			/>,
			{ locale: "en" },
		);
		await screen.findByText("user-uuid-1");

		fireEvent.click(screen.getByTestId("copy-check-in-link"));

		await waitFor(() =>
			expect(clipboard.copyText).toHaveBeenCalledWith(
				`${window.location.origin}/en/w/cgc-academy/events/evt-1/check-in`,
			),
		);
	});

	it("U9：无 workspace slug（壳内路由不可构造）→ 无核销页链接可复制", async () => {
		render(
			<EventModeratorsCard
				workspaceId="ws-1"
				eventId="evt-1"
				workspaceSlug={null}
			/>,
		);
		await screen.findByText("user-uuid-1");

		expect(screen.queryByTestId("copy-check-in-link")).not.toBeInTheDocument();
	});

	// ── #537：回显 fallback 链 / assignedBy / user_not_found ──────────────

	it("回显 fallback 链：displayName 优先；为空落 memberNumber；UUID 为次要信息（title）", async () => {
		lib.fetchEventModerators.mockResolvedValueOnce([
			{
				...ROW,
				userDisplayName: "张小理",
				assignedBy: "owner-uuid",
				assignedByDisplayName: "台主",
				assignedByMemberNumber: "CGC-FFF000",
			},
			ROW,
		]);

		render(<EventModeratorsCard workspaceId="ws-1" eventId="evt-1" />);

		// displayName 有值：主显名字；userId 降为次要信息（title）
		const named = await screen.findByText("张小理");
		expect(named).toHaveAttribute("title", "user-uuid-1");
		// assignedBy 回显（同 fallback 链：displayName 优先）
		expect(screen.getByText("由 台主 指派")).toBeInTheDocument();

		// displayName 为空：落 memberNumber（不显示裸 UUID 作主显）
		expect(screen.getByText("CGC-ABC123")).toBeInTheDocument();
		// assignedBy 为空：不渲染指派行（防 "由  指派" 空名残迹）
		// 元素文本被 testing-library 空白折叠（"由  指派" → "由 指派"），查询串须用折叠后形态
		expect(screen.queryByText("由 指派")).not.toBeInTheDocument();
		const rows = screen.getAllByTitle("user-uuid-1");
		expect(rows).toHaveLength(2);
	});

	it("指派未命中：user_not_found code 出「用户不存在」文案", async () => {
		lib.assignEventModerator.mockResolvedValueOnce({
			result: null,
			errors: [{ code: "user_not_found", message: "user not found" }],
		});

		render(<EventModeratorsCard workspaceId="ws-1" eventId="evt-1" />);
		await screen.findByText("CGC-ABC123");

		fireEvent.change(screen.getByLabelText("邮箱 / CGC 编号 / 用户 ID"), {
			target: { value: "nobody@cgc.example" },
		});
		fireEvent.click(screen.getByRole("button", { name: "指派主理人" }));

		expect(await screen.findByRole("alert")).toHaveTextContent("用户不存在。");
	});
});
