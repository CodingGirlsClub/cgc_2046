import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { createElement, type ReactNode } from "react";
import { render } from "@/test-utils";
import { OfferingDetailPage, OfferingsListPage } from "./offering-pages";

const mocks = vi.hoisted(() => ({
	fetchOffering: vi.fn(),
	fetchMyEnrollment: vi.fn(),
	fetchPendingCount: vi.fn(),
	fetchWorkspaceOfferings: vi.fn(),
	transitionOffering: vi.fn(),
	updateOffering: vi.fn(),
	useWorkspaceBySlug: vi.fn(),
}));

vi.mock("@/lib/events", () => ({
	allowedTransitions: (status: string) =>
		status === "draft" ? ["launch"] : status === "open" ? ["close", "cancel"] : [],
	canManageEvents: (roleNames: string[] = []) =>
		roleNames.some((role) => role === "owner" || role === "admin"),
	createOffering: vi.fn(),
	fetchMyEnrollment: mocks.fetchMyEnrollment,
	fetchOffering: mocks.fetchOffering,
	fetchPendingCount: mocks.fetchPendingCount,
	fetchWorkspaceOfferings: mocks.fetchWorkspaceOfferings,
	formatDeadline: () => "不设截止",
	transitionOffering: mocks.transitionOffering,
	updateOffering: mocks.updateOffering,
}));

vi.mock("@/lib/use-workspace-by-slug", () => ({
	useWorkspaceBySlug: mocks.useWorkspaceBySlug,
}));

vi.mock("@/lib/use-authed", () => ({
	useAuthed: () => ({ authed: true, confirmed: true, userId: "user-1" }),
}));

vi.mock("@/components/workspace-shell", () => ({
	default: ({ children }: { children: ReactNode }) => createElement("main", null, children),
}));

vi.mock("@/components/invite-batch-panel", () => ({
	default: () => null,
}));

vi.mock("@/components/event-status-tag", () => ({
	default: ({ status }: { status: string }) => createElement("span", null, status),
}));

vi.mock("@/components/sponsorship-management", () => ({
	default: () => null,
}));

vi.mock("@/components/speaker-invitation-panel", () => ({
	default: () => null,
}));

vi.mock("@/components/icons", () => ({
	Icon: () => null,
}));

vi.mock("@/lib/public-offerings", () => ({
	parseSponsorshipTiers: () => [],
	submitEnrollment: vi.fn(),
}));

vi.mock("next/link", () => ({
	default: ({ href, children }: { href: string; children: ReactNode }) =>
		createElement("a", { href }, children),
}));

vi.mock("next/navigation", () => ({
	usePathname: () => "/w/demo/events",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));

const WORKSPACE = {
	id: "workspace-1",
	slug: "demo",
	name: "测试工作台",
	joinPolicy: "open" as const,
	sponsorshipEnabled: false,
	myRoleNames: [],
};

beforeEach(() => {
	vi.clearAllMocks();
	mocks.fetchMyEnrollment.mockResolvedValue(false);
	mocks.fetchPendingCount.mockResolvedValue(0);
	mocks.fetchWorkspaceOfferings.mockResolvedValue([]);
	mocks.transitionOffering.mockResolvedValue({ result: null, errors: [] });
	mocks.updateOffering.mockResolvedValue({ result: null, errors: [] });
	mocks.useWorkspaceBySlug.mockReturnValue({
		ws: WORKSPACE,
		loading: false,
		error: null,
		retry: vi.fn(),
	});
});

afterEach(cleanup);

describe("OfferingsListPage 页头", () => {
	it.each([
		["event", "活动"],
		["course", "课程"],
	] as const)("%s 页头不含草稿", async (kind, label) => {
		render(<OfferingsListPage slug="demo" kind={kind} />);

		expect(await screen.findByRole("heading", { name: label })).toBeInTheDocument();
		expect(screen.queryByText(/草稿/)).not.toBeInTheDocument();
		expect(screen.getByText(new RegExp(`${label}与报名`))).toBeInTheDocument();
	});
});

describe("OfferingDetailPage 错误态", () => {
	it("offering null 渲染不可访问文案，而非永久 skeleton", async () => {
		mocks.fetchOffering.mockResolvedValueOnce(null);

		render(<OfferingDetailPage slug="demo" id="missing-event" kind="event" />);

		expect(await screen.findByRole("heading", { name: "该活动不可访问或不存在" })).toBeInTheDocument();
		expect(screen.getByText(/仅工作台内部可见，或已结束/)).toBeInTheDocument();
		expect(document.querySelector(".animate-pulse")).not.toBeInTheDocument();
	});

	it("网络错误不渲染 raw GraphQL message", async () => {
		mocks.fetchOffering.mockRejectedValueOnce(new Error("Cannot query field getEvent"));

		render(<OfferingDetailPage slug="demo" id="broken-event" kind="event" />);

		expect(await screen.findByText("加载失败")).toBeInTheDocument();
		expect(screen.queryByText(/Cannot query field/)).not.toBeInTheDocument();
	});
	it("只读 PlatformAdmin 访客不显示报名写入口", async () => {
		mocks.useWorkspaceBySlug.mockReturnValue({
			ws: { ...WORKSPACE, readOnlyVisitor: true },
			readOnlyVisitor: true,
			loading: false,
			error: null,
			retry: vi.fn(),
		});
		mocks.fetchOffering.mockResolvedValueOnce({
			id: "event-open",
			title: "公开活动",
			status: "open",
			visibility: "workspace",
			enrollmentPolicy: "open",
			registrationDeadline: null,
			capacity: null,
			confirmedCount: 0,
		});

		render(<OfferingDetailPage slug="demo" id="event-open" kind="event" />);

		expect(await screen.findByRole("heading", { name: "公开活动" })).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "报名" })).not.toBeInTheDocument();
	});

	it("fallback 未解析（loading）时不闪现报名 CTA，resolve 为只读后仍不渲染", async () => {
		// rerender 会重跑 fetchOffering effect（deps 相同但组件树重渲染），
		// 用持久实现避免 once 队列耗尽后返回 undefined（不写脆弱 timer）。
		mocks.fetchOffering.mockImplementation(() =>
			Promise.resolve({
				id: "event-open",
				title: "公开活动",
				status: "open",
				visibility: "workspace",
				enrollmentPolicy: "open",
				registrationDeadline: null,
				capacity: null,
				confirmedCount: 0,
			}),
		);
		// 顺序模拟：第一次渲染时 workspace fallback 仍在 loading（offering 先 settle），
		// rerender 后 fallback resolve 为只读访客 —— 两个窗口都不得出现报名按钮。
		mocks.useWorkspaceBySlug
			.mockReturnValueOnce({
				ws: undefined,
				readOnlyVisitor: false,
				loading: true,
				error: null,
				retry: vi.fn(),
			})
			.mockReturnValueOnce({
				ws: { ...WORKSPACE, readOnlyVisitor: true },
				readOnlyVisitor: true,
				loading: false,
				error: null,
				retry: vi.fn(),
			});

		const { rerender } = render(<OfferingDetailPage slug="demo" id="event-open" kind="event" />);

		// offering 已加载而 hook 仍在 loading：CTA 不得闪现
		expect(await screen.findByRole("heading", { name: "公开活动" })).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "报名" })).not.toBeInTheDocument();

		// fallback settle：仍不渲染
		rerender(<OfferingDetailPage slug="demo" id="event-open" kind="event" />);
		expect(screen.queryByRole("button", { name: "报名" })).not.toBeInTheDocument();
	});

	it("普通成员路径：workspace resolve 后仍显示报名入口（门控不误伤成员）", async () => {
		mocks.useWorkspaceBySlug.mockReturnValue({
			ws: WORKSPACE,
			readOnlyVisitor: false,
			loading: false,
			error: null,
			retry: vi.fn(),
		});
		mocks.fetchOffering.mockResolvedValueOnce({
			id: "event-open",
			title: "公开活动",
			status: "open",
			visibility: "workspace",
			enrollmentPolicy: "open",
			registrationDeadline: null,
			capacity: null,
			confirmedCount: 0,
		});

		render(<OfferingDetailPage slug="demo" id="event-open" kind="event" />);

		expect(await screen.findByRole("button", { name: "报名" })).toBeInTheDocument();
	});
});
