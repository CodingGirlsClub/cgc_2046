import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import type { FlashbackCapsule, FlashbackFutureFrame, FlashbackWish } from "@/lib/graphql/flashback";
import Corridor from "./corridor";

/**
 * 未来帧群（U7/版 D）：initiative 场次帧（帧头直链 + 满员/截止不出 CTA）、
 * 公开愿望帧（三色语义 + 已附议态 + 空态）、私人许愿帧仅本人可见且空则隐藏。
 */

vi.mock("@/i18n/navigation", () => ({
	Link: ({ href, children, ...rest }: { href: string; children: React.ReactNode } & Record<string, unknown>) => (
		<a href={href} {...rest}>
			{children}
		</a>
	),
	usePathname: () => "/flashback/capsule",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));

const { useMutationMock } = vi.hoisted(() => ({
	useMutationMock: vi.fn(() => [vi.fn(), { loading: false }]),
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return { ...actual, useMutation: useMutationMock };
});

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

const frame = (initiativeSlug: string, events: FlashbackFutureFrame["events"]): FlashbackFutureFrame => ({
	initiativeSlug,
	initiativeName: initiativeSlug === "hackerstart1024" ? "Hacker Start 1024" : "月度格",
	events,
});

const event = (overrides: Partial<FlashbackFutureFrame["events"][number]> = {}) => ({
	id: "ev-1",
	slug: "hs-a",
	title: "Agent 入门工作坊",
	city: "北京",
	startsAt: "2026-10-24T14:00:00Z",
	capacity: 32,
	confirmedCount: 23,
	registrationDeadline: null,
	...overrides,
});

const wish = (overrides: Partial<FlashbackWish> = {}): FlashbackWish => ({
	id: "w-1",
	content: "一起出一本书",
	city: "北京",
	wisherMasked: "李**",
	endorsementCount: 5,
	endorsedByMe: false,
	mine: false,
	comments: [],
	insertedAt: "2026-09-18T00:00:00Z",
	...overrides,
});

const capsule = (overrides: Partial<FlashbackCapsule> = {}): FlashbackCapsule => ({
	me: {
		id: "me-1",
		fullName: "王晓雨",
		city: "上海",
		occupationThen: "校对",
		participation: "attended",
		appliedAt: "2012-02-20T11:03:00Z",
		today: null,
		quote: null,
		answers: [],
	},
	archives: [],
	futureEvents: [],
	publicWishes: [],
	myPrivateWishes: [],
	cities: [],
	...overrides,
}) as FlashbackCapsule;

describe("Corridor · 未来帧群（U7 版 D）", () => {
	it("initiative 场次帧：帧头直链 /initiatives/{slug}；场次卡报名直链 /events/{slug}（AE1 覆盖）", () => {
		render(
			<Corridor
				capsule={capsule({ futureEvents: [frame("hackerstart1024", [event()])] })}
			/>,
		);

		expect(screen.getByRole("link", { name: "Hacker Start 1024" })).toHaveAttribute(
			"href",
			"/initiatives/hackerstart1024",
		);
		expect(screen.getByRole("link", { name: "报名 →" })).toHaveAttribute("href", "/events/hs-a");
	});

	it("满员/截止场次不出报名 CTA（R2）；帧多 initiative 按序渲染", () => {
		render(
			<Corridor
				capsule={capsule({
					futureEvents: [
						frame("hackerstart1024", [
							event({ id: "ev-full", slug: "full-1", capacity: 10, confirmedCount: 10 }),
							event({ id: "ev-closed", slug: "closed-1", registrationDeadline: "2026-09-01T00:00:00Z" }),
						]),
						frame("monthly", [event({ id: "ev-2", slug: "m-1", title: "月度格场" })]),
					],
				})}
			/>,
		);

		expect(screen.getByText("名额已满")).toBeInTheDocument();
		expect(screen.getByText("报名已截止")).toBeInTheDocument();
		// 仅可报名场次有 CTA
		expect(screen.getAllByRole("link", { name: "报名 →" })).toHaveLength(1);
	});

	it("公开愿望帧：卡面 + 已附议态 + 空态虚线；私人许愿帧空则整体隐藏（R7/R17）", () => {
		render(
			<Corridor
				capsule={capsule({
					publicWishes: [wish(), wish({ id: "w-2", content: "开一门 Rust 系统课", endorsedByMe: true })],
					myPrivateWishes: [],
				})}
			/>,
		);

		expect(screen.getByText("一起出一本书")).toBeInTheDocument();
		expect(screen.getAllByText("已附议").length).toBeGreaterThan(0);
		expect(screen.getByText("+ 许个愿")).toBeInTheDocument();
		// 无私人许愿 → 私人帧不渲染
		expect(screen.queryByText("我的私人许愿")).not.toBeInTheDocument();
	});

	it("私人许愿帧：有私有许愿才出现（R9 仅自己可见——capsule 投影只含本人）", () => {
		render(
			<Corridor
				capsule={capsule({ myPrivateWishes: [wish({ id: "pw-1", content: "想学 Rust" })] })}
			/>,
		);

		expect(screen.getByText("我的私人许愿")).toBeInTheDocument();
		expect(screen.getByText("想学 Rust")).toBeInTheDocument();
	});

	it("无公开愿望：空态虚线入口（R17）", () => {
		render(<Corridor capsule={capsule()} />);

		expect(screen.getByText(/还没有公开的愿望/)).toBeInTheDocument();
	});
});

describe("WishModal 实时反馈（UAT 反馈 ②③）", () => {
	it("模态持有 id：reload 后新 props 的留言立刻显示、附议态立刻翻转", async () => {
		const { rerender } = render(
			<Corridor capsule={capsule({ publicWishes: [wish({ endorsementCount: 2 })] })} />,
		);

		// 打开模态
		fireEvent.click(screen.getByText("一起出一本书"));
		expect(screen.getByRole("dialog")).toBeInTheDocument();
		expect(screen.getAllByRole("button", { name: "附议 +1" }).length).toBeGreaterThan(0);

		// reload 语义：同组件换新 props（新留言 + 已附议）
		const updated = wish({
			endorsementCount: 3,
			endorsedByMe: true,
			comments: [{ id: "c-new", content: "新的留言立刻上墙", commenterMasked: "李**", insertedAt: "2026-09-19T03:00:00Z" }],
		});
		rerender(<Corridor capsule={capsule({ publicWishes: [updated] })} />);

		expect(screen.getByText("新的留言立刻上墙")).toBeInTheDocument();
		expect(screen.getAllByText("已附议").length).toBeGreaterThan(0);
		expect(screen.queryAllByRole("button", { name: "附议 +1" })).toHaveLength(0);
	});
});
