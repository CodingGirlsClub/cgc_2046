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

const ROW = {
	id: "mod-1",
	workspaceId: "ws-1",
	eventId: "evt-1",
	userId: "user-uuid-1",
	assignedBy: null,
	assignedAt: "2026-09-14T00:00:00Z",
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

		fireEvent.change(screen.getByLabelText("用户 ID"), {
			target: { value: "user-uuid-2" },
		});
		fireEvent.click(screen.getByRole("button", { name: "指派主理人" }));

		expect(await screen.findByText("user-uuid-2")).toBeInTheDocument();
		expect(lib.assignEventModerator).toHaveBeenCalledWith(
			"ws-1",
			"evt-1",
			"user-uuid-2",
		);
		expect(screen.getByLabelText("用户 ID")).toHaveValue("");
	});

	it("指派失败内联展示后端错误且列表不变", async () => {
		lib.assignEventModerator.mockResolvedValue({
			result: null,
			errors: [{ code: "not_found", message: "user not found" }],
		});

		render(<EventModeratorsCard workspaceId="ws-1" eventId="evt-1" />);
		await screen.findByText("user-uuid-1");

		fireEvent.change(screen.getByLabelText("用户 ID"), {
			target: { value: "nobody" },
		});
		fireEvent.click(screen.getByRole("button", { name: "指派主理人" }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"user not found",
		);
		expect(screen.queryByText("nobody")).not.toBeInTheDocument();
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
});
