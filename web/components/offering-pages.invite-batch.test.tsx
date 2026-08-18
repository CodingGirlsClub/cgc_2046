import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { createElement, type ReactNode } from "react";
import { render } from "@/test-utils";
import type { OfferingItem } from "@/lib/graphql/events";
import { OfferingDetailPage } from "./offering-pages";

const mocks = vi.hoisted(() => ({
	fetchOffering: vi.fn(),
	fetchMyEnrollment: vi.fn(),
	fetchPendingCount: vi.fn(),
	transitionOffering: vi.fn(),
	updateOffering: vi.fn(),
	useWorkspaceBySlug: vi.fn(),
}));

// i18n Phase 3：payment-errors 表迁 messages errors namespace；测试环境无
// NextIntlClientProvider，mock 同语义的 zh-CN translator（真实迁移语义在
// lib/payment-errors.test.tsx 以 provider 覆盖）
vi.mock("@/lib/payment-errors", async () => {
	const messages = (await import("../messages/zh-CN.json")).default;
	const errors = messages.errors as Record<string, string>;
	const translate = (code: string | null | undefined, fallback: string): string =>
		!code ? fallback : (errors[code] ?? fallback);
	return {
		// 稳定引用：组件 useCallback 依赖它，逐渲染新建会破坏轮询/守卫时序
		usePaymentErrorTranslator: () => translate,
	};
});
vi.mock("@/lib/events", () => ({
	allowedTransitions: (status: string) =>
		status === "draft" ? ["launch"] : status === "open" ? ["close", "cancel"] : [],
	canManageEvents: (roleNames: string[] = []) =>
		roleNames.some((role) => role === "owner" || role === "admin"),
	createOffering: vi.fn(),
	fetchMyEnrollment: mocks.fetchMyEnrollment,
	fetchOffering: mocks.fetchOffering,
	fetchPendingCount: mocks.fetchPendingCount,
	fetchWorkspaceOfferings: vi.fn(),
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
	default: ({
		kind,
		offeringId,
		offeringStatus,
		workspaceId,
	}: {
		kind: string;
		offeringId: string;
		offeringStatus: string;
		workspaceId: string;
	}) =>
		createElement(
			"div",
			{
				"data-testid": "invite-batch-panel",
				"data-kind": kind,
				"data-offering-id": offeringId,
				"data-offering-status": offeringStatus,
				"data-workspace-id": workspaceId,
			},
			"InviteBatchPanel",
		),
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
	usePathname: () => "/w/demo/events/event-1",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));

const OFFERING: OfferingItem = {
	id: "event-1",
	workspaceId: "workspace-1",
	title: "挂点测试活动",
	slug: "event-1",
	status: "open",
	visibility: "public",
	enrollmentPolicy: "invite_only",
	capacity: null,
	confirmedCount: 0,
	registrationDeadline: null,
	sponsorshipEnabled: false,
	sponsorshipTiers: [],
	sponsorshipDeadline: null,
};

const WORKSPACE = {
	id: "workspace-1",
	slug: "demo",
	name: "测试工作台",
	joinPolicy: "open" as const,
	sponsorshipEnabled: false,
	myRoleNames: ["owner" as const],
};

beforeEach(() => {
	vi.clearAllMocks();
	mocks.fetchMyEnrollment.mockResolvedValue(false);
	mocks.fetchPendingCount.mockResolvedValue(0);
	mocks.transitionOffering.mockResolvedValue({ result: null, errors: [] });
	mocks.updateOffering.mockResolvedValue({ result: null, errors: [] });
});

afterEach(cleanup);

async function renderDetail(policy: OfferingItem["enrollmentPolicy"], roles: string[]) {
	mocks.fetchOffering.mockResolvedValueOnce({ ...OFFERING, enrollmentPolicy: policy });
	mocks.useWorkspaceBySlug.mockReturnValue({
		ws: { ...WORKSPACE, myRoleNames: roles },
		loading: false,
		error: null,
		retry: vi.fn(),
	});

	render(<OfferingDetailPage slug="demo" id="event-1" kind="event" />);
	await screen.findByRole("heading", { name: OFFERING.title });
}

describe("OfferingDetailPage InviteBatchPanel 挂点", () => {
	it("manage + invite_only 时渲染批次码面板", async () => {
		await renderDetail("invite_only", ["owner"]);

		expect(screen.getByTestId("invite-batch-panel")).toHaveAttribute(
			"data-workspace-id",
			"workspace-1",
		);
	});

	it.each(["open", "request"] as const)(
		"manage + %s 策略时不渲染批次码面板",
		async (policy) => {
			await renderDetail(policy, ["owner"]);

			expect(screen.queryByTestId("invite-batch-panel")).not.toBeInTheDocument();
		},
	);

	it("非 manage 用户即使 invite_only 也不渲染批次码面板", async () => {
		await renderDetail("invite_only", []);

		expect(screen.queryByTestId("invite-batch-panel")).not.toBeInTheDocument();
	});
});
