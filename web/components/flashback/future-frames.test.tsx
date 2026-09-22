import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import { FLASHBACK_DELETE_WISH } from "@/lib/graphql/flashback";
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
	myWishQuotaRemaining: null,
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

describe("WishFormModal · 年度许愿额度（myWishQuotaRemaining）", () => {
	const openForm = () => {
		fireEvent.click(screen.getByText("+ 许个愿"));
		expect(screen.getByRole("dialog")).toBeInTheDocument();
	};

	it("登录态显示剩余条数：「今年还可许 2 条」", () => {
		render(<Corridor capsule={capsule({ myWishQuotaRemaining: 2 })} token="tok" />);
		openForm();

		expect(screen.getByText("今年还可许 2 条")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "许下这个愿" })).toBeEnabled();
	});

	it("额度为 0：显示已用完文案且提交按钮禁用", () => {
		render(<Corridor capsule={capsule({ myWishQuotaRemaining: 0 })} token="tok" />);
		openForm();

		expect(screen.getByText("今年许愿名额已用完（每年最多 3 条，删除不退还名额）")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "许下这个愿" })).toBeDisabled();
	});

	it("未登录（myWishQuotaRemaining 为 null）：不显示额度行，提交可用", () => {
		render(<Corridor capsule={capsule({ myWishQuotaRemaining: null })} token={null} />);
		openForm();

		expect(screen.queryByText(/今年还可许/)).not.toBeInTheDocument();
		expect(screen.queryByText(/许愿名额已用完/)).not.toBeInTheDocument();
		expect(screen.getByRole("button", { name: "许下这个愿" })).toBeEnabled();
	});

	it("mutation 抛 flashback_wish_quota_exceeded：内联文案 + 触发 refetch 刷新额度（F2）", async () => {
		const createWish = vi.fn().mockRejectedValue({
			errors: [{ message: "quota exceeded", extensions: { code: "flashback_wish_quota_exceeded" } }],
		});
		useMutationMock.mockReturnValue([createWish, { loading: false }]);
		const onChanged = vi.fn();

		const { rerender } = render(
			<Corridor capsule={capsule({ myWishQuotaRemaining: 1 })} token="tok" onChanged={onChanged} />,
		);
		openForm();
		fireEvent.change(screen.getByPlaceholderText(/你想参加什么/), { target: { value: "想办一场读书会" } });
		fireEvent.click(screen.getByRole("button", { name: "许下这个愿" }));

		expect(createWish).toHaveBeenCalledTimes(1);
		expect(await screen.findByRole("alert")).toHaveTextContent(
			"今年许愿名额已用完（每年最多 3 条，删除不退还名额）。",
		);
		// F2：拒绝即刷新额度——onChanged 触发胶囊 refetch（私有也占额度，再试必败，
		// 不存在「改私有再试」的出路）；模态保持打开，用户可关闭
		expect(onChanged).toHaveBeenCalledTimes(1);
		expect(screen.getByRole("dialog")).toBeInTheDocument();

		// refetch 完成：新 capsule 额度 0 → 额度行变用完文案 + 提交禁用
		rerender(<Corridor capsule={capsule({ myWishQuotaRemaining: 0 })} token="tok" onChanged={onChanged} />);
		expect(await screen.findByText("今年许愿名额已用完（每年最多 3 条，删除不退还名额）")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "许下这个愿" })).toBeDisabled();
	});

	it("无 code 的失败：兜底 database_error 文案，不触发 refetch（只有 quota_exceeded 才刷）", async () => {
		const createWish = vi.fn().mockRejectedValue(new Error("network down"));
		useMutationMock.mockReturnValue([createWish, { loading: false }]);
		const onChanged = vi.fn();

		render(<Corridor capsule={capsule({ myWishQuotaRemaining: 3 })} token="tok" onChanged={onChanged} />);
		openForm();
		fireEvent.change(screen.getByPlaceholderText(/你想参加什么/), { target: { value: "想办一场读书会" } });
		fireEvent.click(screen.getByRole("button", { name: "许下这个愿" }));

		expect(await screen.findByRole("alert")).toHaveTextContent("服务暂时不可用，请稍后重试。");
		expect(onChanged).not.toHaveBeenCalled();
		expect(screen.getByRole("dialog")).toBeInTheDocument();
	});
});

describe("WishFormModal · wish2 U8（署名/期望地/两档/三态/撤回）", () => {
	const openForm = () => {
		fireEvent.click(screen.getByText("+ 许个愿"));
	};
	const fillAndSubmit = () => {
		fireEvent.change(screen.getByPlaceholderText(/你想参加什么/), { target: { value: "办一场重聚" } });
		fireEvent.click(screen.getByRole("button", { name: "许下这个愿" }));
	};

	it("默认公开档：加粗明示文案在 <strong> 内（R6 结构断言 pin），公开 radio 默认选中", () => {
		render(<Corridor capsule={capsule()} token="tok" />);
		openForm();

		const strong = document.querySelector(".fb-wish-visibility strong");
		expect(strong).not.toBeNull();
		expect(strong).toHaveTextContent("公开 = 挂上许愿树，任何人可见");
		const radios = screen.getAllByRole("radio", { name: /公开 = 挂上许愿树/ }) as HTMLInputElement[];
		expect(radios[0].checked).toBe(true);
	});

	it("提交公开档：variables 带 publicListingConsent=true + 署名 + 期望地原样（归一在服务端）", async () => {
		const createWish = vi.fn().mockResolvedValue({
			data: { flashbackCreateWish: { id: "w-new", endorsementCount: 0, endorsedByMe: false, status: "listed" } },
		});
		useMutationMock.mockReturnValue([createWish, { loading: false }]);

		render(<Corridor capsule={capsule()} token="tok" />);
		openForm();
		fireEvent.change(screen.getByPlaceholderText(/想在哪座城市/), { target: { value: "成都市" } });
		fireEvent.click(screen.getByRole("radio", { name: /实名展示/ }));
		fillAndSubmit();

		expect(createWish).toHaveBeenCalledTimes(1);
		expect(createWish.mock.calls[0][0].variables).toMatchObject({
			visibility: "public",
			publicListingConsent: true,
			signatureChoice: "display_name",
			expectedCity: "成都市",
		});
	});

	it("listed 反馈：挂树文案 + 去树上看看 + 撤回入口；撤回后 withdrawn 文案", async () => {
		const createWish = vi.fn().mockResolvedValue({
			data: { flashbackCreateWish: { id: "w-new", endorsementCount: 0, endorsedByMe: false, status: "listed" } },
		});
		const deleteWish = vi.fn().mockResolvedValue({ data: { flashbackDeleteWish: true } });
		useMutationMock.mockImplementation(() => {
			const calls = useMutationMock.mock.calls as unknown as Array<[unknown]>;
			const last = calls[calls.length - 1];
			return last?.[0] === FLASHBACK_DELETE_WISH
				? [deleteWish, { loading: false }]
				: [createWish, { loading: false }];
		});

		render(<Corridor capsule={capsule()} token="tok" />);
		openForm();
		fillAndSubmit();

		expect(await screen.findByText("挂上树了 🎉")).toBeInTheDocument();
		const viewLink = screen.getByText("去树上看看它").closest("a");
		expect(viewLink).toHaveAttribute("href", "/flashback/wishes?item=w-new");

		fireEvent.click(screen.getByRole("button", { name: "撤回这条愿望" }));
		expect(await screen.findByText("已撤回——公开面上不再可见")).toBeInTheDocument();
		expect(deleteWish).toHaveBeenCalledWith({ variables: { token: "tok", wishId: "w-new" } });
	});

	it("pending_review 反馈：审核通过后挂上树（不假装纸签已公开出现）", async () => {
		const createWish = vi.fn().mockResolvedValue({
			data: { flashbackCreateWish: { id: "w-pr", endorsementCount: 0, endorsedByMe: false, status: "pending_review" } },
		});
		useMutationMock.mockReturnValue([createWish, { loading: false }]);

		render(<Corridor capsule={capsule()} token="tok" />);
		openForm();
		fillAndSubmit();

		expect(await screen.findByText("已提交")).toBeInTheDocument();
		expect(screen.getByText("审核通过后挂上树。")).toBeInTheDocument();
		// 未挂树 → 无「去树上看看」
		expect(screen.queryByText("去树上看看它")).not.toBeInTheDocument();
	});

	it("说给主办方听档：指定文案反馈 + consent=false", async () => {
		const createWish = vi.fn().mockResolvedValue({
			data: { flashbackCreateWish: { id: "w-pv", endorsementCount: 0, endorsedByMe: false, status: "private" } },
		});
		useMutationMock.mockReturnValue([createWish, { loading: false }]);

		render(<Corridor capsule={capsule()} token="tok" />);
		openForm();
		fireEvent.click(screen.getByRole("radio", { name: /说给主办方听/ }));
		fillAndSubmit();

		expect(createWish.mock.calls[0][0].variables).toMatchObject({
			visibility: "private",
			publicListingConsent: false,
		});
		expect(await screen.findByText("收到。")).toBeInTheDocument();
		expect(
			screen.getByText("这条愿望只有你和平台能看到——我们会认真看，也许很快来聊聊。"),
		).toBeInTheDocument();
	});

	it("机审拒绝：flashback_content_rejected 映射换种说法文案", async () => {
		const createWish = vi.fn().mockRejectedValue({
			errors: [{ message: "rejected", extensions: { code: "flashback_content_rejected" } }],
		});
		useMutationMock.mockReturnValue([createWish, { loading: false }]);

		render(<Corridor capsule={capsule()} token="tok" />);
		openForm();
		fillAndSubmit();

		expect(await screen.findByRole("alert")).toHaveTextContent("这句话没能挂上树，换种说法试试。");
	});
});
