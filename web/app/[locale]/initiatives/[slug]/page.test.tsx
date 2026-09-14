import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import InitiativePage from "./page";

const { fetchPublicInitiative } = vi.hoisted(() => ({
	fetchPublicInitiative: vi.fn(),
}));

vi.mock("@/lib/graphql/initiatives", () => ({ fetchPublicInitiative }));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), back: vi.fn() }),
	usePathname: () => "/initiatives/hackerstart1024",
}));

const BASE_EVENT = {
	id: "e1",
	slug: "evt-1",
	visibility: "public",
	startsAt: "2026-10-13T15:22:30Z",
	endsAt: null,
	registrationDeadline: null,
	venue: null,
	minParticipants: 8,
	archived: false,
};

function event(partial: Record<string, unknown>) {
	return { ...BASE_EVENT, ...partial };
}

const PAYLOAD = {
	id: "i1",
	name: "Hackerstart 1024 全国黑客松",
	slug: "hackerstart1024",
	hashtag: "#hackerstart1024",
	description: "1024 程序员节全国巡回黑客松。",
	status: "open",
	cityCount: 2,
	eventCount: 4,
	confirmedCount: 14,
	qualifiedEventCount: 1,
	cities: [
		{
			city: "长沙市",
			events: [
				event({
					id: "e1",
					slug: "1024-changsha-01",
					title: "长沙站",
					status: "open",
					confirmedCount: 4,
					qualificationStatus: "pending",
					qualificationBadge: "short_by",
					shortBy: 4,
				}),
				event({
					id: "e2",
					slug: "1024-shanghai-01",
					title: "上海站",
					status: "open",
					confirmedCount: 8,
					qualificationStatus: "confirmed",
					qualificationBadge: "confirmed",
					shortBy: null,
				}),
				event({
					id: "e3",
					slug: "1024-beijing-01",
					title: "北京站",
					status: "cancelled",
					confirmedCount: 2,
					qualificationStatus: "underfilled",
					qualificationBadge: "cancelled",
					shortBy: null,
					archived: true,
				}),
			],
		},
		{
			city: "深圳市",
			events: [
				event({
					id: "e4",
					slug: "1024-shenzhen-01",
					title: "深圳站",
					status: "closed",
					confirmedCount: 0,
					qualificationStatus: "pending",
					qualificationBadge: "closed",
					shortBy: null,
					archived: true,
				}),
			],
		},
	],
};

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("/initiatives/[slug] 公开页", () => {
	it("渲染四项计数、城市分组与后端派生徽章矩阵", async () => {
		fetchPublicInitiative.mockResolvedValue(PAYLOAD);

		render(<InitiativePage params={Promise.resolve({ slug: "hackerstart1024" })} />);

		expect(
			await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" }),
		).toBeInTheDocument();

		const stats = document.querySelector(".initiative-stats")!;
		expect(stats.textContent).toContain("2");
		expect(stats.textContent).toContain("4");
		expect(stats.textContent).toContain("14");
		expect(stats.textContent).toContain("1");

		expect(screen.getByRole("heading", { name: "长沙市" })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: "深圳市" })).toBeInTheDocument();

		expect(screen.getByText("还差 4 人")).toBeInTheDocument();
		expect(screen.getAllByText("已成班").length).toBeGreaterThanOrEqual(2);
		expect(screen.getByText("已取消")).toBeInTheDocument();
		expect(screen.getByText("已结束")).toBeInTheDocument();

		expect(
			screen.getByRole("link", { name: /长沙站/ }),
		).toHaveAttribute("href", "/events/1024-changsha-01");
	});

	it("加载失败渲染 notFound 与返回入口", async () => {
		fetchPublicInitiative.mockRejectedValue(new Error("network"));

		render(<InitiativePage params={Promise.resolve({ slug: "missing" })} />);

		expect(
			await screen.findByRole("heading", { name: "活动不存在" }),
		).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "返回" })).toBeInTheDocument();
	});
});
