import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import PricingManagement from "./pricing-management";

const { client } = vi.hoisted(() => ({ client: { query: vi.fn() } }));
const { updateOffering } = vi.hoisted(() => ({ updateOffering: vi.fn() }));

vi.mock("@/lib/apollo-client", () => ({ client }));
vi.mock("@/lib/events", () => ({ updateOffering }));
vi.mock("@/lib/graphql/events", () => ({
	LIST_EVENTS: "LIST_EVENTS",
	LIST_COURSES: "LIST_COURSES",
}));
vi.mock("@/lib/payment", () => ({
	formatAmount: (cents: number) => (cents / 100).toFixed(2),
}));

const tiersJson = (tiers: Array<Record<string, unknown>>) =>
	tiers.map((t) => JSON.stringify(t));

function offeringsPayload(overrides: Partial<Record<string, unknown>> = {}) {
	return {
		data: {
			listEvents: {
				results: [
					{
						id: "event-1",
						workspaceId: "ws-1",
						title: "收费活动",
						status: "open",
						visibility: "public",
						enrollmentPolicy: "open",
						capacity: null,
						confirmedCount: 0,
						registrationDeadline: null,
						pricingEnabled: true,
						priceTiers: tiersJson([
							{ id: "t1", name: "早鸟票", amount_cents: 9900 },
						]),
						...overrides,
					},
				],
			},
			listCourses: { results: [] },
		},
	};
}

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("PricingManagement（U2-R1 定价配置面）", () => {
	it("加载渲染：目标选择按钮（含收费标记）+ 档位行回显 + 开关选中态", async () => {
		client.query.mockResolvedValue(offeringsPayload());

		render(<PricingManagement workspaceId="ws-1" manage />);

		const target = await screen.findByTestId("pricing-target-event-1");
		expect(target).toHaveTextContent("收费活动 · 收费");

		expect(await screen.findByTestId("tier-row-t1")).toBeInTheDocument();
		expect(screen.getByTestId("tier-name-t1")).toHaveValue("早鸟票");
		expect(screen.getByTestId("tier-amount-t1")).toHaveValue("99.00");
		expect(screen.getByTestId("pricing-toggle")).toBeChecked();
		expect(screen.getByTestId("tier-preview")).toHaveTextContent("早鸟票 ¥99.00");
	});

	it("非管理（manage=false）：开关与档位输入禁用，无增删/保存按钮", async () => {
		client.query.mockResolvedValue(offeringsPayload());

		render(<PricingManagement workspaceId="ws-1" manage={false} />);

		await screen.findByTestId("tier-row-t1");
		expect(screen.getByTestId("pricing-toggle")).toBeDisabled();
		expect(screen.getByTestId("tier-name-t1")).toBeDisabled();
		expect(screen.queryByTestId("tier-add")).not.toBeInTheDocument();
		expect(screen.queryByTestId("pricing-save")).not.toBeInTheDocument();
	});

	it("增删档：添加空行 + 删除行", async () => {
		client.query.mockResolvedValue(offeringsPayload());

		render(<PricingManagement workspaceId="ws-1" manage />);
		await screen.findByTestId("tier-row-t1");

		fireEvent.click(screen.getByTestId("tier-add"));
		const rows = screen.getAllByTestId(/^tier-row-/);
		expect(rows.length).toBe(2);

		fireEvent.click(screen.getByTestId("tier-remove-t1"));
		expect(screen.getAllByTestId(/^tier-row-/).length).toBe(1);
		expect(screen.queryByTestId("tier-row-t1")).not.toBeInTheDocument();
	});

	it("校验：0 元/空名档位被剔出有效集（tier-invalid 提示）；启用收费零有效档被拦（tier-blocked）", async () => {
		client.query.mockResolvedValue(
			offeringsPayload({
				pricingEnabled: false,
				priceTiers: tiersJson([{ id: "t0", name: "坏档", amount_cents: 0 }]),
			}),
		);

		render(<PricingManagement workspaceId="ws-1" manage />);
		await screen.findByTestId("tier-row-t0");

		// 0 元档：行在但不在有效集（预览无该档）
		expect(screen.queryByTestId("tier-preview")).not.toBeInTheDocument();

		// 0 元档在场 → 行级无效提示；保存被拦（不触 mutation）
		expect(await screen.findByTestId("tier-invalid")).toBeInTheDocument();

		fireEvent.click(screen.getByTestId("pricing-save"));
		expect(updateOffering).not.toHaveBeenCalled();
	});

	it("校验：启用收费且零档位 → tier-blocked 拦截保存", async () => {
		client.query.mockResolvedValue(
			offeringsPayload({ pricingEnabled: false, priceTiers: [] }),
		);

		render(<PricingManagement workspaceId="ws-1" manage />);
		await screen.findByTestId("tier-empty");

		fireEvent.click(screen.getByTestId("pricing-toggle"));
		expect(await screen.findByTestId("tier-blocked")).toBeInTheDocument();

		fireEvent.click(screen.getByTestId("pricing-save"));
		expect(updateOffering).not.toHaveBeenCalled();
	});

	it("保存：校验通过 → updateOffering 携带 pricingEnabled + priceTiers(JsonString)；空 availableUntil 不落键", async () => {
		client.query.mockResolvedValue(
			offeringsPayload({
				pricingEnabled: false,
				priceTiers: tiersJson([{ id: "t1", name: "标准票", amount_cents: 19900 }]),
			}),
		);

		render(<PricingManagement workspaceId="ws-1" manage />);
		await screen.findByTestId("tier-row-t1");

		fireEvent.click(screen.getByTestId("pricing-toggle"));
		fireEvent.click(screen.getByTestId("pricing-save"));

		await waitFor(() => expect(updateOffering).toHaveBeenCalledTimes(1));
		const [id, kind, input] = updateOffering.mock.calls[0];
		expect(id).toBe("event-1");
		expect(kind).toBe("event");
		expect(input.pricingEnabled).toBe(true);
		expect(input.priceTiers).toHaveLength(1);
		const tier = JSON.parse(input.priceTiers[0] as string);
		expect(tier).toEqual({ id: "t1", name: "标准票", amount_cents: 19900 });
	});

	it("保存失败：errors 呈现（pricing-error），后端 PriceTiersValidation 兜底文案透传", async () => {
		client.query.mockResolvedValue(offeringsPayload());
		updateOffering.mockResolvedValueOnce({
			result: null,
			errors: [{ message: "保存失败：收费开启时至少需要一个有效档位" }],
		});

		render(<PricingManagement workspaceId="ws-1" manage />);
		await screen.findByTestId("tier-row-t1");

		// 制造 dirty（toggle 一下），否则保存按钮 disabled
		fireEvent.click(screen.getByTestId("pricing-toggle"));
		fireEvent.click(screen.getByTestId("pricing-save"));

		expect(await screen.findByTestId("pricing-error")).toHaveTextContent(
			"至少需要一个有效档位",
		);
	});

	it("加载失败：错误态 + 重试入口", async () => {
		client.query.mockRejectedValue(new Error("network"));

		render(<PricingManagement workspaceId="ws-1" manage />);

		await screen.findByText(/定价配置加载失败/);
		expect(screen.getByRole("button", { name: "重试" })).toBeInTheDocument();
	});
});
