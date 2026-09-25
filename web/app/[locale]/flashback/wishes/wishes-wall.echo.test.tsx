import { describe, it, expect, vi, beforeEach } from "vitest";
import { screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import WishesWall from "./wishes-wall";
import type { FlashbackPublicWish, FlashbackPublicWishEcho } from "@/lib/graphql/flashback";

const queryImpl = vi.hoisted(() => vi.fn());
vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: queryImpl,
		mutate: vi.fn().mockResolvedValue({ data: {} }),
	},
}));
vi.mock("@apollo/client/react", async (importOriginal) => {
	const mod = await importOriginal<typeof import("@apollo/client/react")>();
	return { ...mod, useMutation: () => [vi.fn().mockResolvedValue({ data: {} })] };
});
vi.mock("@/lib/auth-provider", () => ({
	useAuthed: () => ({ authed: false, user: null, loading: false }),
}));

const baseWish: FlashbackPublicWish = {
	id: "w-1",
	content: "想再回到 2014 年的北京",
	city: "北京",
	signature: "王**",
	expectationCount: 2,
	endorsementCount: 1,
	contributionDistribution: {},
	expectedByViewer: false,
	endorsedByViewer: false,
	latestEcho: null,
	echoCount: 0,
	echoes: [],
	listedAt: "2026-09-20T08:00:00Z",
	insertedAt: "2026-09-20T08:00:00Z",
};

const echo: FlashbackPublicWishEcho = {
	id: "e-1",
	content: "主办方:第一季已定档",
	status: "published",
	publishedAt: "2026-09-20T09:00:00Z",
	correctedAt: null,
};
const echoCorrected: FlashbackPublicWishEcho = {
	id: "e-2",
	content: "主办方:第一季改期",
	status: "corrected",
	publishedAt: "2026-09-21T09:00:00Z",
	correctedAt: "2026-09-22T08:00:00Z",
};

const wishWithEcho: FlashbackPublicWish = {
	...baseWish,
	id: "w-echo",
	latestEcho: echo,
	echoCount: 1,
	echoes: [echo],
};
const wishWith2Echoes: FlashbackPublicWish = {
	...baseWish,
	id: "w-echo2",
	latestEcho: echoCorrected,
	echoCount: 2,
	echoes: [echo, echoCorrected],
};


beforeEach(() => {
	queryImpl.mockReset().mockImplementation(({ query }) => {
		const src: string =
			(query as { loc?: { source?: { body?: string } } })?.loc?.source?.body ?? "";
		if (src.includes("flashbackCities")) {
			return Promise.resolve({ data: { flashbackCities: [] } });
		}
		if (src.includes("flashbackPublicWishes")) {
			return Promise.resolve({
				data: {
					flashbackPublicWishes:
						(globalThis as { __wishes?: unknown[] }).__wishes ?? [],
				},
			});
		}
		return Promise.resolve({ data: {} });
	});
});

function setWishes(wishes: unknown[]) {
	(globalThis as { __wishes?: unknown[] }).__wishes = wishes;
}

describe("WishesWall · 公开树回响标记与详情(#836)", () => {
	it("无回响的愿望在 wish row 没有「回响」标记,selected 大卡不渲染回响区", async () => {
		setWishes([baseWish]);
		render(<WishesWall showIntro={false} />);
		await screen.findByText("想再回到 2014 年的北京");
		expect(screen.queryByTestId("fb-wish-row-echo")).toBeNull();
		expect(screen.queryByTestId("fb-selected-echo-badge")).toBeNull();
		expect(screen.queryByTestId("fb-wish-echo-card")).toBeNull();
	});

	it("有回响的 wish row 显示可访问名「回响」标记", async () => {
		setWishes([wishWithEcho]);
		render(<WishesWall showIntro={false} />);
		await screen.findByText("想再回到 2014 年的北京");
		await screen.findByText("想再回到 2014 年的北京");
		const badge = screen.getByTestId("fb-selected-echo-badge");
		expect(badge.getAttribute("aria-label")).toMatch(/回响|Echo/);
		expect(badge.textContent).toMatch(/回响|Echo/);
	});

	it("selected 大卡有回响时渲染 WishEchoCard,含署名/最新一条", async () => {
		setWishes([wishWithEcho]);
		render(<WishesWall showIntro={false} />);
		await screen.findByText("想再回到 2014 年的北京");
		const card = screen.getByTestId("fb-wish-echo-card");
		expect(card).toBeInTheDocument();
		expect(card.getAttribute("aria-label")).toBe("回响");
		expect(screen.getByText("主办方")).toBeInTheDocument();
		expect(screen.getByText("主办方:第一季已定档")).toBeInTheDocument();
	});

	it("多条回响:展开后按时间正序展示全部;corrected 显示已更正徽章", async () => {
		setWishes([wishWith2Echoes]);
		render(<WishesWall showIntro={false} />);
		await screen.findByText("想再回到 2014 年的北京");
		expect(screen.getByText("主办方:第一季改期")).toBeInTheDocument();
		expect(screen.queryByText("主办方:第一季已定档")).toBeNull();
		fireEvent.click(screen.getByTestId("fb-wish-echo-toggle"));
		const items = screen.getAllByTestId("fb-wish-echo");
		expect(items).toHaveLength(2);
		expect(items[0].textContent).toContain("第一季已定档");
		expect(items[1].textContent).toContain("第一季改期");
		expect(screen.getByTestId("fb-wish-echo-corrected")).toBeInTheDocument();
	});

	it("en 渲染:回响标记、署名与徽标的英文文案", async () => {
		setWishes([wishWith2Echoes]);
		render(<WishesWall showIntro={false} />, { locale: "en" });
		await screen.findByText("想再回到 2014 年的北京");
		const badge = screen.getByTestId("fb-selected-echo-badge");
		expect(badge.textContent).toBe("Echo");
		expect(badge.getAttribute("aria-label")).toBe("This wish has received an echo");
		expect(screen.getByText("Organizers")).toBeInTheDocument();
		fireEvent.click(screen.getByTestId("fb-wish-echo-toggle"));
		expect(screen.getByText("Corrected")).toBeInTheDocument();
	});
});
