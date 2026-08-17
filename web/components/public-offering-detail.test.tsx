import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import PublicOfferingDetailPage from "./public-offering-detail";

const mocks = vi.hoisted(() => ({
	fetchPublicOffering: vi.fn(),
	submitEnrollment: vi.fn(),
}));

vi.mock("@/lib/public-offerings", () => ({
	fetchPublicOffering: mocks.fetchPublicOffering,
	parseSponsorshipTiers: () => [],
	submitEnrollment: mocks.submitEnrollment,
}));

vi.mock("@/lib/use-authed", () => ({
	useAuthed: () => ({ authed: true, confirmed: true, userId: "user-1" }),
}));

vi.mock("next/navigation", () => ({
	useParams: () => ({ slug: "paid-event" }),
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), refresh: vi.fn() }),
}));

vi.mock("@/components/learning/course-map-section", () => ({
	default: () => null,
}));

vi.mock("@/components/sponsorship-intent-form", () => ({
	default: () => null,
}));
vi.mock("next/navigation", () => ({
	useParams: () => ({ slug: "paid-event" }),
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), refresh: vi.fn() }),
	usePathname: () => "/events/paid-event",
}));

const PAID_OFFERING = {
	id: "evt-paid",
	slug: "paid-event",
	title: "收费活动",
	description: null,
	status: "open",
	visibility: "public",
	enrollmentPolicy: "open",
	registrationDeadline: null,
	pricingEnabled: true,
	availablePriceTiers: [
		JSON.stringify({ id: "tier-1", name: "早鸟", amount_cents: 100 }),
		JSON.stringify({ id: "tier-2", name: "标准", amount_cents: 19900 }),
	],
};

beforeEach(() => {
	vi.clearAllMocks();
	mocks.fetchPublicOffering.mockResolvedValue(PAID_OFFERING);
});

afterEach(cleanup);

describe("公开收费详情页档位选择（e2e #3）", () => {
	it("免费项不渲染档位选择器（R4 零变化）", async () => {
		mocks.fetchPublicOffering.mockResolvedValue({
			...PAID_OFFERING,
			pricingEnabled: false,
			availablePriceTiers: null,
		});

		render(<PublicOfferingDetailPage kind="event" />);

		expect(await screen.findByRole("button", { name: "提交报名" })).toBeInTheDocument();
		expect(screen.queryByTestId("price-tier-picker")).not.toBeInTheDocument();
	});

	it("收费项：渲染档位 → 未选档被前端拒 → 选档后 tierId 随报名提交 → payment_pending 出「去支付」", async () => {
		mocks.submitEnrollment.mockResolvedValueOnce({
			result: { id: "enr-1", status: "payment_pending" },
			errors: [],
		});

		render(<PublicOfferingDetailPage kind="event" />);

		const picker = await screen.findByTestId("price-tier-picker");
		expect(picker).toBeInTheDocument();
		expect(screen.getByText("¥1.00")).toBeInTheDocument();
		expect(screen.getByText("¥199.00")).toBeInTheDocument();

		// 未选档 → 前端拒绝，不触 mutation
		fireEvent.click(screen.getByRole("button", { name: "提交报名" }));
		expect(await screen.findByRole("alert")).toHaveTextContent("请先选择价格档位");
		expect(mocks.submitEnrollment).not.toHaveBeenCalled();

		// 选档 → 提交携带 tierId
		fireEvent.click(screen.getByTestId("price-tier-tier-2"));
		fireEvent.click(screen.getByRole("button", { name: "提交报名" }));

		await waitFor(() => expect(mocks.submitEnrollment).toHaveBeenCalledTimes(1));
		expect(mocks.submitEnrollment).toHaveBeenCalledWith(
			expect.objectContaining({ tierId: "tier-2", eventId: "evt-paid" }),
		);

		// payment_pending 态：待支付提示 + 去支付入口
		expect(await screen.findByText(/待支付（名额已保留）/)).toBeInTheDocument();
		const payLink = screen.getByRole("link", { name: "去支付" });
		expect(payLink).toHaveAttribute("href", "/orders/new?enrollmentId=enr-1");
	});

	it("收费项全过期档（availablePriceTiers 空）：无可售档位提示，不渲染档位 radio", async () => {
		mocks.fetchPublicOffering.mockResolvedValue({
			...PAID_OFFERING,
			availablePriceTiers: [],
		});

		render(<PublicOfferingDetailPage kind="event" />);

		expect(
			await screen.findByTestId("no-available-tier"),
		).toHaveTextContent("当前无可售档位，请联系组织者。");
		expect(screen.queryByTestId("price-tier-tier-1")).not.toBeInTheDocument();
	});

	it("后端 :tier_id_required 错误 → 映射为档位引导文案（错误分支不再死胡同）", async () => {
		mocks.submitEnrollment.mockResolvedValueOnce({
			result: null,
			errors: [
				{
					message: "a price tier is required for paid enrollment",
					short_message: "a price tier is required for paid enrollment",
				},
			],
		});

		render(<PublicOfferingDetailPage kind="event" />);

		await screen.findByTestId("price-tier-picker");
		fireEvent.click(screen.getByTestId("price-tier-tier-1"));
		fireEvent.click(screen.getByRole("button", { name: "提交报名" }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"该报名为收费项，请先选择价格档位。",
		);
	});
});
