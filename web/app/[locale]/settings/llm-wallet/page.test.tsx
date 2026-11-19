import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import { formatDateTime } from "@/lib/format";
import {
	CREATE_LLM_PAYMENT_ORDER,
	LLM_PAYMENT_ORDER,
	MY_LLM_USAGE_LOGS,
	MY_LLM_WALLET,
} from "@/lib/graphql/llm-gateway";
import PersonalLlmWalletPage from "./page";

const { queryMock, mutateMock, toDataUrlMock, useAuthedMock } = vi.hoisted(
	() => ({
		queryMock: vi.fn(),
		mutateMock: vi.fn(),
		toDataUrlMock: vi.fn(),
		useAuthedMock: vi.fn(),
	}),
);

vi.mock("qrcode", () => ({
	default: { toDataURL: toDataUrlMock },
}));

vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: queryMock,
		mutate: mutateMock,
	},
}));

vi.mock("@/lib/use-authed", () => ({
	useAuthed: useAuthedMock,
}));

vi.mock("@/components/site-page", () => ({
	default: ({ children }: { children: React.ReactNode }) => (
		<div data-testid="mock-site-page">{children}</div>
	),
}));

const WALLET_FIXTURE = {
	walletId: "wallet-1",
	cachedBalanceMc: "35000000",
	heldMc: "2500000",
	availableMc: "32500000",
	maxConcurrentStreams: 3,
	status: "active",
	remainingPercentage: 82,
	activeGrants: [
		{
			id: "grant-1",
			sourceType: "subscription",
			initialMc: "29000000",
			remainingMc: "25000000",
			expiresAt: "2026-12-19T00:00:00Z",
			status: "active",
			insertedAt: "2026-11-19T00:00:00Z",
		},
		{
			id: "grant-2",
			sourceType: "pack",
			initialMc: "10000000",
			remainingMc: "10000000",
			expiresAt: null,
			status: "active",
			insertedAt: "2026-11-10T00:00:00Z",
		},
	],
};

function makeLog(index: number, isoTime: string) {
	return {
		id: `log-${index}`,
		sessionId: `sess-${index}`,
		logicalModel: "cgc-default",
		billingMode: "exact",
		promptCacheHitTokens: "4000",
		promptCacheMissTokens: "1000",
		completionTokens: "600",
		reasoningTokens: "0",
		chargedMc: "12500",
		ttfbMs: 320,
		durationMs: 1450,
		insertedAt: isoTime,
	};
}

beforeEach(() => {
	vi.clearAllMocks();
	useAuthedMock.mockReturnValue({ authed: true, confirmed: true });
	toDataUrlMock.mockResolvedValue("data:image/png;base64,WALLET_QR");
});

afterEach(() => {
	vi.useRealTimers();
	cleanup();
});

describe("/settings/llm-wallet 个人 LLM 算力钱包页", () => {
	it("未登录时提示登录引导", () => {
		useAuthedMock.mockReturnValue({ authed: false, confirmed: true });

		render(<PersonalLlmWalletPage />);

		expect(screen.getByRole("link", { name: "前往登录" })).toHaveAttribute(
			"href",
			"/login?next=/settings/llm-wallet",
		);
	});

	it("加载态显示加载占位", () => {
		queryMock.mockReturnValue(new Promise(() => {}));

		render(<PersonalLlmWalletPage />);

		expect(screen.getByTestId("wallet-loading")).toBeInTheDocument();
		expect(screen.getByTestId("usage-logs-loading")).toBeInTheDocument();
	});

	it("成功加载：渲染余额、冻结、活跃授信与用量流水", async () => {
		const log0 = makeLog(1, "2026-11-19T06:00:00Z");
		queryMock.mockImplementation(({ query }) => {
			if (query === MY_LLM_WALLET) {
				return Promise.resolve({ data: { myLlmWallet: WALLET_FIXTURE } });
			}
			if (query === MY_LLM_USAGE_LOGS) {
				return Promise.resolve({ data: { myLlmUsageLogs: [log0] } });
			}
			return Promise.resolve({ data: {} });
		});

		render(<PersonalLlmWalletPage />);

		expect(await screen.findByTestId("wallet-available-cny")).toHaveTextContent(
			"¥32.50",
		);
		expect(screen.getByTestId("wallet-cached-cny")).toHaveTextContent("¥35.00");
		expect(screen.getByTestId("wallet-held-cny")).toHaveTextContent("¥2.50");
		expect(screen.getByTestId("wallet-status-badge")).toHaveTextContent("正常");

		const grantsTable = screen.getByTestId("grants-table");
		expect(within(grantsTable).getByText("月度订阅")).toBeInTheDocument();
		expect(within(grantsTable).getByText("永久算力包")).toBeInTheDocument();
		expect(within(grantsTable).getByText("永久有效")).toBeInTheDocument();
		expect(
			within(grantsTable).getByText(
				formatDateTime(WALLET_FIXTURE.activeGrants[0].expiresAt),
			),
		).toBeInTheDocument();

		const logsTable = screen.getByTestId("usage-logs-table");
		expect(within(logsTable).getByText("cgc-default")).toBeInTheDocument();
		expect(within(logsTable).getByText("¥0.0125")).toBeInTheDocument();
		expect(
			within(logsTable).getByText(formatDateTime(log0.insertedAt)),
		).toBeInTheDocument();
		expect(
			screen.queryByTestId("usage-logs-load-more"),
		).not.toBeInTheDocument();
	});

	it("空钱包与空用量记录渲染空态", async () => {
		queryMock.mockImplementation(({ query }) => {
			if (query === MY_LLM_WALLET) {
				return Promise.resolve({ data: { myLlmWallet: null } });
			}
			if (query === MY_LLM_USAGE_LOGS) {
				return Promise.resolve({ data: { myLlmUsageLogs: [] } });
			}
			return Promise.resolve({ data: {} });
		});

		render(<PersonalLlmWalletPage />);

		expect(await screen.findByTestId("wallet-empty")).toBeInTheDocument();
		expect(await screen.findByTestId("usage-logs-empty")).toBeInTheDocument();
	});

	it("钱包与日志加载失败时支持独立重试恢复", async () => {
		let walletAttempts = 0;
		let logAttempts = 0;
		queryMock.mockImplementation(({ query }) => {
			if (query === MY_LLM_WALLET) {
				walletAttempts += 1;
				if (walletAttempts === 1) return Promise.reject(new Error("wallet err"));
				return Promise.resolve({ data: { myLlmWallet: WALLET_FIXTURE } });
			}
			if (query === MY_LLM_USAGE_LOGS) {
				logAttempts += 1;
				if (logAttempts === 1) return Promise.reject(new Error("logs err"));
				return Promise.resolve({ data: { myLlmUsageLogs: [] } });
			}
			return Promise.resolve({ data: {} });
		});

		render(<PersonalLlmWalletPage />);

		const walletErr = await screen.findByTestId("wallet-error");
		const logsErr = await screen.findByTestId("usage-logs-error");
		expect(walletErr).toHaveTextContent("wallet err");
		expect(logsErr).toHaveTextContent("logs err");

		fireEvent.click(within(walletErr).getByRole("button", { name: "重试" }));
		fireEvent.click(within(logsErr).getByRole("button", { name: "重试" }));

		expect(await screen.findByTestId("wallet-available-cny")).toHaveTextContent(
			"¥32.50",
		);
		expect(await screen.findByTestId("usage-logs-empty")).toBeInTheDocument();
	});

	it("订阅 ¥29 扫码支付并轮询到 paid 后自动刷新钱包", async () => {
		let paid = false;
		queryMock.mockImplementation(({ query }) => {
			if (query === MY_LLM_WALLET) {
				return Promise.resolve({
					data: {
						myLlmWallet: paid
							? { ...WALLET_FIXTURE, availableMc: "61500000" }
							: WALLET_FIXTURE,
					},
				});
			}
			if (query === MY_LLM_USAGE_LOGS) {
				return Promise.resolve({ data: { myLlmUsageLogs: [] } });
			}
			if (query === LLM_PAYMENT_ORDER) {
				paid = true;
				return Promise.resolve({
					data: {
						llmPaymentOrder: {
							id: "ord-sub-29",
							userId: "u-1",
							workspaceId: null,
							orderKind: "llm_subscription",
							provider: "alipay_qr",
							outTradeNo: "SUB20261119029",
							amountCents: 2900,
							creditsMc: "29000000",
							status: "paid",
							expiresAt: null,
							paidAt: "2026-11-19T07:01:00Z",
							insertedAt: "2026-11-19T07:00:00Z",
						},
					},
				});
			}
			return Promise.resolve({ data: {} });
		});

		mutateMock.mockResolvedValue({
			data: {
				createLlmPaymentOrder: {
					order: {
						id: "ord-sub-29",
						status: "pending",
						amountCents: 2900,
						creditsMc: "29000000",
						outTradeNo: "SUB20261119029",
						paidAt: null,
					},
					credential: { type: "qr_code", code_url: "https://qr.alipay.com/test" },
				},
			},
		});

		render(<PersonalLlmWalletPage />);
		await screen.findByTestId("wallet-summary");

		vi.useFakeTimers({ shouldAdvanceTime: true });

		// 切换到支付宝扫码并购买 ¥29 月卡
		fireEvent.click(screen.getByRole("button", { name: "支付宝扫码" }));
		fireEvent.click(screen.getByTestId("buy-sub-2900"));

		expect(await screen.findByTestId("llm-qr-image")).toHaveAttribute(
			"src",
			"data:image/png;base64,WALLET_QR",
		);
		expect(mutateMock).toHaveBeenCalledWith({
			mutation: CREATE_LLM_PAYMENT_ORDER,
			variables: expect.objectContaining({
				orderKind: "llm_subscription",
				provider: "alipay_qr",
				amountCents: 2900,
			}),
		});

		await act(async () => {
			await vi.advanceTimersByTimeAsync(2_100);
		});

		expect(await screen.findByTestId("llm-qr-paid-banner")).toBeInTheDocument();
		await waitFor(() =>
			expect(screen.getByTestId("wallet-available-cny")).toHaveTextContent(
				"¥61.50",
			),
		);
	});

	it("用量流水支持 before 游标加载更多", async () => {
		const firstPage = Array.from({ length: 20 }, (_, i) =>
			makeLog(i + 1, `2026-11-19T05:${String(59 - i).padStart(2, "0")}:00Z`),
		);
		const secondPage = [makeLog(21, "2026-11-19T04:00:00Z")];

		queryMock.mockImplementation(({ query, variables }) => {
			if (query === MY_LLM_WALLET) {
				return Promise.resolve({ data: { myLlmWallet: WALLET_FIXTURE } });
			}
			if (query === MY_LLM_USAGE_LOGS) {
				if (variables?.before) {
					return Promise.resolve({ data: { myLlmUsageLogs: secondPage } });
				}
				return Promise.resolve({ data: { myLlmUsageLogs: firstPage } });
			}
			return Promise.resolve({ data: {} });
		});

		render(<PersonalLlmWalletPage />);

		const loadMoreBtn = await screen.findByTestId("usage-logs-load-more");
		fireEvent.click(loadMoreBtn);

		await waitFor(() =>
			expect(queryMock).toHaveBeenCalledWith(
				expect.objectContaining({
					query: MY_LLM_USAGE_LOGS,
					variables: {
						limit: 20,
						before: firstPage[19].insertedAt,
					},
				}),
			),
		);

		const table = screen.getByTestId("usage-logs-table");
		await waitFor(() =>
			expect(within(table).getAllByRole("row")).toHaveLength(22), // 1 thead + 21 tbody rows
		);
		expect(
			screen.queryByTestId("usage-logs-load-more"),
		).not.toBeInTheDocument();
	});
});
