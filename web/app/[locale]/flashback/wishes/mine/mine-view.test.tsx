import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import MyWishesView from "./mine-view";
import { FLASHBACK_MY_WISHES } from "@/lib/graphql/flashback";

/**
 * M11 我的愿望页契约：
 * - 登录即可（无档案可用）：未登录给登录链接（回跳本页），不发查询；
 * - 渲染年度剩余名额 + 全部未删除愿望（含公开/待审/私密状态）；
 * - listed 愿望带「在许愿树查看」；删除必须二次确认，确认才发
 *   flashbackDeleteWish（会话入口，不传 token），成功后重拉（额度随之更新）；
 * - 取消删除零 mutation；空态给去许愿出口。
 */

const queryMock = vi.fn();
const mutateMock = vi.fn();

vi.mock("@/lib/apollo-client", () => ({
	client: { query: (opts: unknown) => queryMock(opts), mutate: (opts: unknown) => mutateMock(opts) },
}));

const { auth } = vi.hoisted(() => ({ auth: vi.fn() }));
vi.mock("@/lib/auth-provider", () => ({ useAuthed: auth }));
vi.mock("@/i18n/navigation", () => ({
	usePathname: () => "/flashback/wishes/mine",
	Link: ({ href, children, ...rest }: React.ComponentProps<"a">) => (
		<a href={href} {...rest}>
			{children}
		</a>
	),
}));

const wishes = [
	{ id: "w-1", content: "愿望一", city: "北京", signature: "王**", visibility: "public", status: "listed", insertedAt: "2026-09-20T00:00:00Z" },
	{ id: "w-2", content: "愿望二", city: null, signature: "匿名", visibility: "public", status: "pending_review", insertedAt: "2026-09-21T00:00:00Z" },
	{ id: "w-3", content: "愿望三", city: null, signature: "王**", visibility: "private", status: "private", insertedAt: "2026-09-22T00:00:00Z" },
];

function mockMyWishes(list = wishes, quotaRemaining = 2) {
	queryMock.mockImplementation((opts: { query: unknown }) => {
		if (opts.query === FLASHBACK_MY_WISHES) {
			return Promise.resolve({ data: { flashbackMyWishes: { quotaRemaining, wishes: list } } });
		}
		return Promise.reject(new Error("unexpected query"));
	});
}

beforeEach(() => {
	queryMock.mockReset();
	mutateMock.mockReset();
	mutateMock.mockResolvedValue({ data: { flashbackDeleteWish: true } });
});

afterEach(cleanup);

describe("我的愿望页（M11）", () => {
	it("未登录：给登录链接（回跳本页），不发查询", async () => {
		auth.mockReturnValue({ authed: false, confirmed: false });
		render(<MyWishesView />);
		const link = await screen.findByRole("link", { name: "登录后查看我的愿望" });
		expect(link).toHaveAttribute("href", "/login?next=%2Fflashback%2Fwishes%2Fmine");
		expect(queryMock).not.toHaveBeenCalled();
	});

	it("已登录：渲染名额、三条状态与 listed 的树链接", async () => {
		auth.mockReturnValue({ authed: true, confirmed: true });
		mockMyWishes();
		render(<MyWishesView />);
		expect(await screen.findByTestId("fb-my-wishes-quota")).toHaveTextContent("今年还可以许 2 个愿望");
		const statuses = screen.getAllByTestId("fb-my-wish-status").map((n) => n.textContent);
		expect(statuses).toEqual(["已公开", "待审核", "仅自己和主办方可见"]);
		expect(screen.getByRole("link", { name: "在许愿树查看 →" })).toHaveAttribute("href", "/flashback/wishes?item=w-1");
	});

	it("删除二次确认：确认后带 wishId 发 mutation 并重拉", async () => {
		auth.mockReturnValue({ authed: true, confirmed: true });
		mockMyWishes();
		render(<MyWishesView />);
		await screen.findByTestId("fb-my-wishes-quota");
		fireEvent.click(screen.getAllByRole("button", { name: "删除" })[0]);
		const dialog = await screen.findByTestId("fb-my-wish-delete-dialog");
		expect(dialog).toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: "确认删除" }));
		await waitFor(() => expect(mutateMock).toHaveBeenCalled());
		expect(mutateMock.mock.calls[0][0].variables).toEqual({ wishId: "w-1" });
		await waitFor(() => expect(queryMock).toHaveBeenCalledTimes(2));
		expect(screen.getByRole("status")).toHaveTextContent("已删除");
	});

	it("取消删除零 mutation", async () => {
		auth.mockReturnValue({ authed: true, confirmed: true });
		mockMyWishes();
		render(<MyWishesView />);
		await screen.findByTestId("fb-my-wishes-quota");
		fireEvent.click(screen.getAllByRole("button", { name: "删除" })[1]);
		fireEvent.click(await screen.findByRole("button", { name: "先不删" }));
		expect(mutateMock).not.toHaveBeenCalled();
		expect(screen.queryByTestId("fb-my-wish-delete-dialog")).not.toBeInTheDocument();
	});

	it("空态给去许愿出口", async () => {
		auth.mockReturnValue({ authed: true, confirmed: true });
		mockMyWishes([], 3);
		render(<MyWishesView />);
		expect(await screen.findByText("还没有许过愿望——写下第一颗。")).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "去许愿" })).toHaveAttribute("href", "/flashback/wishes");
	});
});
