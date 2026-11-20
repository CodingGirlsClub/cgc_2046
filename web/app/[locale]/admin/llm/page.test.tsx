import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import {
	ADMIN_GRANT_USER_LLM_CREDITS,
	ADMIN_LLM_USAGE_ANALYTICS,
	ADMIN_TOPUP_WORKSPACE_LLM_POOL,
	ADMIN_UPDATE_USER_LLM_CONCURRENCY,
	ADMIN_UPDATE_USER_LLM_WALLET_STATUS,
} from "@/lib/graphql/llm-gateway";
import AdminLlmPage from "./page";

const { queryMock, mutateMock } = vi.hoisted(() => ({
	queryMock: vi.fn(),
	mutateMock: vi.fn(),
}));

vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: queryMock,
		mutate: mutateMock,
	},
}));

const SAMPLE_METRICS = [
	{
		day: "2026-11-18",
		upstreamChannel: "deepseek-direct",
		requestCount: 100,
		abortedCount: 4,
		waivedCount: 1,
		cacheHitTokens: "800000",
		cacheMissTokens: "200000",
		completionTokens: "150000",
		totalChargedMc: "30000000",
		totalUpstreamCostMc: "18000000",
		grossMarginMc: "12000000",
	},
	{
		day: "2026-11-17",
		upstreamChannel: "volcengine-backup",
		requestCount: 50,
		abortedCount: 2,
		waivedCount: 0,
		cacheHitTokens: "100000",
		cacheMissTokens: "100000",
		completionTokens: "50000",
		totalChargedMc: "10000000",
		totalUpstreamCostMc: "8000000",
		grossMarginMc: "2000000",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(() => {
	cleanup();
});

describe("/admin/llm 平台算力运营与毛利控制台", () => {
	it("加载态显示占位提示", () => {
		queryMock.mockReturnValue(new Promise(() => {}));

		render(<AdminLlmPage />);

		expect(screen.getByTestId("admin-llm-loading")).toBeInTheDocument();
	});

	it("成功加载：渲染 KPI 汇总卡片、明细表并支持切换 7 / 14 / 30 天窗口", async () => {
		queryMock.mockResolvedValue({
			data: { adminLlmUsageAnalytics: SAMPLE_METRICS },
		});

		render(<AdminLlmPage />);

		expect(await screen.findByTestId("admin-llm-table")).toBeInTheDocument();
		expect(queryMock).toHaveBeenCalledWith(
			expect.objectContaining({
				query: ADMIN_LLM_USAGE_ANALYTICS,
				variables: { days: 14 },
			}),
		);

		// 总营收 ¥40.00, 成本 ¥26.00, 毛利 ¥14.00 (35.0%), 缓存命中 900k/1.2M = 75.0%, 中断+免单 7/150 = 4.7%
		expect(screen.getByTestId("kpi-revenue")).toHaveTextContent("¥40.00");
		expect(screen.getByTestId("kpi-cost")).toHaveTextContent("¥26.00");
		expect(screen.getByTestId("kpi-margin")).toHaveTextContent("¥14.00");
		expect(screen.getByTestId("kpi-margin-pct")).toHaveTextContent("35.0%");
		expect(screen.getByTestId("kpi-cache-hit")).toHaveTextContent("75.0%");
		expect(screen.getByTestId("kpi-abort-waived")).toHaveTextContent("4.7%");

		const table = screen.getByTestId("admin-llm-table");
		expect(within(table).getByText("deepseek-direct")).toBeInTheDocument();
		expect(within(table).getByText("volcengine-backup")).toBeInTheDocument();

		// 切换到近 30 天
		fireEvent.click(screen.getByRole("button", { name: "近 30 天" }));
		await waitFor(() =>
			expect(queryMock).toHaveBeenLastCalledWith(
				expect.objectContaining({
					query: ADMIN_LLM_USAGE_ANALYTICS,
					variables: { days: 30 },
				}),
			),
		);

		// 切换到近 7 天
		fireEvent.click(screen.getByRole("button", { name: "近 7 天" }));
		await waitFor(() =>
			expect(queryMock).toHaveBeenLastCalledWith(
				expect.objectContaining({
					query: ADMIN_LLM_USAGE_ANALYTICS,
					variables: { days: 7 },
				}),
			),
		);
	});

	it("空数据时渲染空态提示", async () => {
		queryMock.mockResolvedValue({ data: { adminLlmUsageAnalytics: [] } });

		render(<AdminLlmPage />);

		expect(await screen.findByTestId("admin-llm-empty")).toBeInTheDocument();
		expect(screen.getByTestId("kpi-revenue")).toHaveTextContent("¥0.00");
	});

	it("查询失败时显示错误态，点击重试可恢复", async () => {
		queryMock
			.mockRejectedValueOnce(new Error("analytics boom"))
			.mockResolvedValueOnce({
				data: { adminLlmUsageAnalytics: SAMPLE_METRICS },
			});

		render(<AdminLlmPage />);

		const alert = await screen.findByTestId("admin-llm-error");
		expect(alert).toHaveTextContent("analytics boom");

		fireEvent.click(within(alert).getByRole("button", { name: "重试" }));
		expect(await screen.findByTestId("admin-llm-table")).toBeInTheDocument();
	});

	it("工作台算力池充值表单：校验、BigInt 提交与成功反馈", async () => {
		queryMock.mockResolvedValue({ data: { adminLlmUsageAnalytics: [] } });
		mutateMock.mockResolvedValue({
			data: {
				adminTopupWorkspaceLlmPool: {
					workspaceId: "ws-001",
					creditPoolMc: "150000000",
					updatedAt: "2026-11-19T10:00:00Z",
					recentBatches: [],
				},
			},
		});

		render(<AdminLlmPage />);
		await screen.findByTestId("admin-llm-empty");

		const form = screen.getByTestId("admin-topup-form");
		// 空表单校验
		fireEvent.click(within(form).getByRole("button", { name: "确认充值" }));
		expect(within(form).getByRole("alert")).toHaveTextContent("工作台 ID");

		fireEvent.change(within(form).getByLabelText("工作台 ID"), {
			target: { value: "ws-001" },
		});
		fireEvent.change(within(form).getByLabelText("金额（人民币 CNY）"), {
			target: { value: "50.25" },
		});
		fireEvent.click(within(form).getByRole("button", { name: "确认充值" }));

		await waitFor(() =>
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: ADMIN_TOPUP_WORKSPACE_LLM_POOL,
				variables: { workspaceId: "ws-001", amountMc: "50250000" },
			}),
		);
		expect(await within(form).findByRole("status")).toHaveTextContent("¥150.00");
	});

	it("赠送个人算力表单：提交含可选到期时间与失败反馈", async () => {
		queryMock.mockResolvedValue({ data: { adminLlmUsageAnalytics: [] } });
		mutateMock
			.mockResolvedValueOnce({
				data: {
					adminGrantUserLlmCredits: {
						walletId: "w-1",
						cachedBalanceMc: "25000000",
						heldMc: "0",
						availableMc: "25000000",
						remainingPercentage: 100,
						status: "active",
					},
				},
			})
			.mockRejectedValueOnce(new Error("user not found"));

		render(<AdminLlmPage />);
		await screen.findByTestId("admin-llm-empty");

		const form = screen.getByTestId("admin-gift-form");
		fireEvent.change(within(form).getByLabelText("用户 ID"), {
			target: { value: "user-42" },
		});
		fireEvent.change(within(form).getByLabelText("金额（人民币 CNY）"), {
			target: { value: "25" },
		});
		fireEvent.click(within(form).getByRole("button", { name: "确认赠送" }));

		await waitFor(() =>
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: ADMIN_GRANT_USER_LLM_CREDITS,
				variables: {
					userId: "user-42",
					amountMc: "25000000",
					expiresAt: null,
				},
			}),
		);
		expect(await within(form).findByRole("status")).toHaveTextContent("¥25.00");

		// 错误分支
		fireEvent.change(within(form).getByLabelText("金额（人民币 CNY）"), {
			target: { value: "10" },
		});
		fireEvent.click(within(form).getByRole("button", { name: "确认赠送" }));
		expect(await within(form).findByRole("alert")).toHaveTextContent(
			"user not found",
		);
	});

	it("风控操作表单：支持冻结附带原因、解冻与调整并发流上限", async () => {
		queryMock.mockResolvedValue({ data: { adminLlmUsageAnalytics: [] } });
		mutateMock
			.mockResolvedValueOnce({
				data: {
					adminUpdateUserLlmWalletStatus: {
						walletId: "w-1",
						status: "frozen",
						frozenReason: "高频异常调用",
						maxConcurrentStreams: 3,
					},
				},
			})
			.mockResolvedValueOnce({
				data: {
					adminUpdateUserLlmConcurrency: {
						walletId: "w-1",
						status: "frozen",
						frozenReason: "高频异常调用",
						maxConcurrentStreams: 8,
					},
				},
			});

		render(<AdminLlmPage />);
		await screen.findByTestId("admin-llm-empty");

		const statusForm = screen.getByTestId("admin-wallet-status-form");
		fireEvent.change(within(statusForm).getByLabelText("用户 ID"), {
			target: { value: "user-99" },
		});
		fireEvent.change(
			within(statusForm).getByLabelText("冻结原因（选填，将展示给用户）"),
			{
				target: { value: "高频异常调用" },
			},
		);
		fireEvent.click(
			within(statusForm).getByRole("button", { name: "确认更新状态" }),
		);

		await waitFor(() =>
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: ADMIN_UPDATE_USER_LLM_WALLET_STATUS,
				variables: {
					userId: "user-99",
					status: "frozen",
					frozenReason: "高频异常调用",
				},
			}),
		);
		expect(await within(statusForm).findByRole("status")).toHaveTextContent(
			"user-99",
		);

		const concForm = screen.getByTestId("admin-wallet-concurrency-form");
		fireEvent.change(within(concForm).getByLabelText("用户 ID"), {
			target: { value: "user-99" },
		});
		fireEvent.change(within(concForm).getByLabelText(/最大并发流数/), {
			target: { value: "8" },
		});
		fireEvent.click(
			within(concForm).getByRole("button", { name: "确认更新上限" }),
		);

		await waitFor(() =>
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: ADMIN_UPDATE_USER_LLM_CONCURRENCY,
				variables: {
					userId: "user-99",
					maxConcurrentStreams: 8,
				},
			}),
		);
		expect(await within(concForm).findByRole("status")).toHaveTextContent("8");
	});
});
