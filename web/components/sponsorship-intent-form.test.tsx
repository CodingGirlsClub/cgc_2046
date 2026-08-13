import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import SponsorshipIntentForm from "./sponsorship-intent-form";

const { mutate } = vi.hoisted(() => ({ mutate: vi.fn() }));

vi.mock("@/lib/apollo-client", () => ({ client: { mutate } }));

const TIERS = [
	{
		id: "t-1",
		name: "冠名",
		amountSuggestion: 10_000,
		benefits: ["logo 展示位"],
		exclusive: true,
	},
	{
		id: "t-2",
		name: "标准",
		amountSuggestion: 2_000,
		benefits: ["报名页露出"],
		exclusive: false,
	},
];

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("E-3 #48 赞助意向表单", () => {
	it("档位选项渲染（含建议金额与独占标记来源档位）", () => {
		render(
			<SponsorshipIntentForm
				eventId="ev-1"
				sponsorUserId="u-1"
				tiers={TIERS}
			/>,
		);

		expect(screen.getByLabelText("公司名")).toBeInTheDocument();
		expect(screen.getByLabelText("联系邮箱")).toBeInTheDocument();
		expect(screen.getByRole("combobox")).toBeInTheDocument();
		expect(screen.getByText(/冠名（建议 ¥10000）/)).toBeInTheDocument();
		expect(screen.getByText(/标准（建议 ¥2000）/)).toBeInTheDocument();
	});

	it("提交成功 → createSponsorship 入参正确 + 「已提交」中间态", async () => {
		mutate.mockResolvedValue({
			data: {
				createSponsorship: {
					result: { id: "sp-1", level: "event", status: "pending", tierName: "冠名" },
				},
			},
		});

		render(
			<SponsorshipIntentForm
				eventId="ev-1"
				sponsorUserId="u-1"
				tiers={TIERS}
			/>,
		);

		fireEvent.change(screen.getByLabelText("公司名"), { target: { value: "Acme" } });
		fireEvent.change(screen.getByLabelText("联系邮箱"), {
			target: { value: "sponsor@example.com" },
		});
		fireEvent.change(screen.getByLabelText("联系电话"), { target: { value: "13800000000" } });
		fireEvent.change(screen.getByLabelText("意向金额"), { target: { value: "10000" } });
		fireEvent.click(screen.getByRole("button", { name: "提交赞助意向" }));

		await waitFor(() => expect(mutate).toHaveBeenCalledOnce());
		expect(mutate.mock.calls[0][0].variables).toEqual({
			input: {
				level: "event",
				eventId: "ev-1",
				sponsorUserId: "u-1",
				tierId: "t-1",
				amount: 10_000,
				companyName: "Acme",
				contactEmail: "sponsor@example.com",
				contactPhone: "13800000000",
				message: null,
			},
		});

		await waitFor(() =>
			expect(screen.getByText("✓ 赞助意向已提交")).toBeInTheDocument(),
		);
	});

	it("公司名/邮箱缺失 → 前置校验报错，不发 mutation", async () => {
		render(
			<SponsorshipIntentForm
				eventId="ev-1"
				sponsorUserId="u-1"
				tiers={TIERS}
			/>,
		);

		fireEvent.click(screen.getByRole("button", { name: "提交赞助意向" }));

		await waitFor(() =>
			expect(screen.getByRole("alert")).toHaveTextContent("必填"),
		);
		expect(mutate).not.toHaveBeenCalled();
	});

	it("后端拒绝 → 回显错误信息", async () => {
		mutate.mockResolvedValue({
			data: {
				createSponsorship: {
					result: null,
					errors: [{ message: "sponsor already has a non-terminal sponsorship" }],
				},
			},
		});

		render(
			<SponsorshipIntentForm
				eventId="ev-1"
				sponsorUserId="u-1"
				tiers={TIERS}
			/>,
		);

		fireEvent.change(screen.getByLabelText("公司名"), { target: { value: "Acme" } });
		fireEvent.change(screen.getByLabelText("联系邮箱"), {
			target: { value: "sponsor@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: "提交赞助意向" }));

		await waitFor(() =>
			expect(screen.getByRole("alert")).toHaveTextContent("non-terminal sponsorship"),
		);
	});
});
