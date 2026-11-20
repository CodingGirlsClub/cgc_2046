import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import { formatDateTime } from "@/lib/format";
import {
	CREATE_LLM_PAYMENT_ORDER,
	DISTRIBUTE_WORKSPACE_LLM_CREDITS,
	LLM_PAYMENT_ORDER,
	WORKSPACE_LLM_POOL,
} from "@/lib/graphql/llm-gateway";
import { WORKSPACE_MEMBERS } from "@/lib/graphql/workspace";
import WorkspaceLlmPoolPage from "./page";

const { queryMock, mutateMock, toDataUrlMock, useWorkspaceBySlugMock } =
	vi.hoisted(() => ({
		queryMock: vi.fn(),
		mutateMock: vi.fn(),
		toDataUrlMock: vi.fn(),
		useWorkspaceBySlugMock: vi.fn(),
	}));

vi.mock("next/navigation", () => ({
	useParams: () => ({ slug: "cgc-lab" }),
	usePathname: () => "/w/cgc-lab/llm-pool",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

vi.mock("qrcode", () => ({
	default: { toDataURL: toDataUrlMock },
}));

vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: queryMock,
		mutate: mutateMock,
	},
}));

vi.mock("@/lib/use-workspace-by-slug", () => ({
	useWorkspaceBySlug: useWorkspaceBySlugMock,
}));

vi.mock("@/components/workspace-shell", () => ({
	default: ({ children }: { children: React.ReactNode }) => (
		<div data-testid="mock-shell">{children}</div>
	),
}));

vi.mock("@/components/members-tabs", () => ({
	default: () => <nav data-testid="mock-tabs" />,
}));

const MOCK_WS = {
	id: "ws-lab-1",
	slug: "cgc-lab",
	name: "CGC Lab",
	myAbilities: ["manage_members", "list_members"],
};

const POOL_FIXTURE = {
	workspaceId: "ws-lab-1",
	creditPoolMc: "500000000",
	updatedAt: "2026-11-19T08:00:00Z",
	recentBatches: [
		{
			id: "batch-1",
			actorUserId: "u-owner-1",
			perMemberMc: "10000000",
			memberCount: 5,
			totalGrantedMc: "50000000",
			expiresAt: "2026-12-31T23:59:00Z",
			idempotencyKey: "idem-batch-1",
			insertedAt: "2026-11-18T12:00:00Z",
		},
	],
	recentPoolEntries: [
		{
			id: "entry-1",
			entryType: "order_topup",
			deltaMc: "100000000",
			paymentOrderId: "ord-topup-1",
			workspaceBatchId: null,
			actorUserId: "u-owner-1",
			insertedAt: "2026-11-19T07:00:00Z",
		},
		{
			id: "entry-2",
			entryType: "batch_grant_debit",
			deltaMc: "-50000000",
			paymentOrderId: null,
			workspaceBatchId: "batch-1",
			actorUserId: "u-owner-1",
			insertedAt: "2026-11-18T12:00:00Z",
		},
	],
};

beforeEach(() => {
	vi.clearAllMocks();
	useWorkspaceBySlugMock.mockReturnValue({
		ws: MOCK_WS,
		loading: false,
		readOnlyVisitor: false,
	});
	toDataUrlMock.mockResolvedValue("data:image/png;base64,MOCK_QR");
});

afterEach(() => {
	vi.useRealTimers();
	cleanup();
});

describe("/w/[slug]/llm-pool 工作台算力池页", () => {
	it("加载态显示加载提示", () => {
		queryMock.mockReturnValue(new Promise(() => {}));

		render(<WorkspaceLlmPoolPage />);

		expect(screen.getByTestId("workspace-pool-loading")).toBeInTheDocument();
	});

	it("成功加载：渲染算力池 CNY 与 mc 余额及最近派发批次表", async () => {
		queryMock.mockResolvedValue({ data: { workspaceLlmPool: POOL_FIXTURE } });

		render(<WorkspaceLlmPoolPage />);

		expect(await screen.findByTestId("workspace-pool-cny")).toHaveTextContent(
			"¥500.00",
		);
		expect(screen.getByTestId("workspace-pool-mc")).toHaveTextContent(
			"500,000,000 mc",
		);

		const table = screen.getByTestId("workspace-batches-table");
		expect(within(table).getByText("¥10.00")).toBeInTheDocument();
		expect(within(table).getByText("¥50.00")).toBeInTheDocument();
		expect(within(table).getByText("idem-batch-1")).toBeInTheDocument();
		expect(
			within(table).getByText(formatDateTime(POOL_FIXTURE.recentBatches[0].insertedAt)),
		).toBeInTheDocument();
	});

	it("无派发记录时渲染空态", async () => {
		queryMock.mockResolvedValue({
			data: {
				workspaceLlmPool: { ...POOL_FIXTURE, recentBatches: [] },
			},
		});

		render(<WorkspaceLlmPoolPage />);

		expect(
			await screen.findByTestId("workspace-batches-empty"),
		).toBeInTheDocument();
	});

	it("加载失败时渲染错误与重试按钮，点击重试恢复", async () => {
		queryMock
			.mockRejectedValueOnce(new Error("pool unavailable"))
			.mockResolvedValueOnce({ data: { workspaceLlmPool: POOL_FIXTURE } });

		render(<WorkspaceLlmPoolPage />);

		const errBox = await screen.findByTestId("workspace-pool-error");
		expect(errBox).toHaveTextContent("pool unavailable");

		fireEvent.click(within(errBox).getByRole("button", { name: "重试" }));
		expect(await screen.findByTestId("workspace-pool-cny")).toHaveTextContent(
			"¥500.00",
		);
	});

	it("批量派发表单：携带 UUID idempotencyKey 派发并刷新算力池", async () => {
		queryMock.mockResolvedValue({ data: { workspaceLlmPool: POOL_FIXTURE } });
		mutateMock.mockResolvedValue({
			data: {
				distributeWorkspaceLlmCredits: {
					id: "batch-2",
					perMemberMc: "15000000",
					memberCount: 4,
					totalGrantedMc: "60000000",
					idempotentReplay: false,
				},
			},
		});

		render(<WorkspaceLlmPoolPage />);
		await screen.findByTestId("workspace-pool-summary");

		const form = screen.getByTestId("workspace-distribute-form");
		fireEvent.change(within(form).getByLabelText("每人派发额度（CNY）"), {
			target: { value: "15" },
		});
		fireEvent.click(within(form).getByRole("button", { name: "立即派发" }));

		await waitFor(() =>
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: DISTRIBUTE_WORKSPACE_LLM_CREDITS,
				variables: expect.objectContaining({
					workspaceId: "ws-lab-1",
					perMemberMc: "15000000",
					expiresAt: null,
					idempotencyKey: expect.stringMatching(/^[0-9a-f-]{36}$/i),
				}),
			}),
		);
		expect(await within(form).findByRole("status")).toHaveTextContent("¥60.00");
	});

	it("扫码充值：创单生成二维码、轮询至 paid 刷新池余额，且卸载清理定时器", async () => {
		let pollCount = 0;
		queryMock.mockImplementation(({ query }) => {
			if (query === WORKSPACE_LLM_POOL) {
				return Promise.resolve({
					data: {
						workspaceLlmPool:
							pollCount > 0
								? { ...POOL_FIXTURE, creditPoolMc: "600000000" }
								: POOL_FIXTURE,
					},
				});
			}
			if (query === LLM_PAYMENT_ORDER) {
				pollCount += 1;
				return Promise.resolve({
					data: {
						llmPaymentOrder: {
							id: "ord-pool-1",
							userId: "u-owner-1",
							workspaceId: "ws-lab-1",
							orderKind: "llm_workspace_pool_topup",
							provider: "wechat_native",
							outTradeNo: "LLM20261119001",
							amountCents: 10000,
							creditsMc: "100000000",
							status: "paid",
							expiresAt: null,
							paidAt: "2026-11-19T08:05:00Z",
							insertedAt: "2026-11-19T08:04:00Z",
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
						id: "ord-pool-1",
						status: "pending",
						amountCents: 10000,
						creditsMc: "100000000",
						outTradeNo: "LLM20261119001",
						paidAt: null,
					},
					credential: { type: "qr_code", code_url: "weixin://wxpay/test" },
				},
			},
		});

		const { unmount } = render(<WorkspaceLlmPoolPage />);
		await screen.findByTestId("workspace-pool-summary");

		vi.useFakeTimers({ shouldAdvanceTime: true });

		const topupForm = screen.getByTestId("workspace-topup-form");
		fireEvent.click(
			within(topupForm).getByRole("button", { name: "生成支付二维码" }),
		);

		expect(await screen.findByTestId("llm-qr-image")).toHaveAttribute(
			"src",
			"data:image/png;base64,MOCK_QR",
		);
		expect(mutateMock).toHaveBeenCalledWith({
			mutation: CREATE_LLM_PAYMENT_ORDER,
			variables: expect.objectContaining({
				orderKind: "llm_workspace_pool_topup",
				provider: "wechat_native",
				amountCents: 10000,
				workspaceId: "ws-lab-1",
			}),
		});

		await act(async () => {
			await vi.advanceTimersByTimeAsync(2_100);
		});

		expect(await screen.findByTestId("llm-qr-paid-banner")).toBeInTheDocument();
		await waitFor(() =>
			expect(screen.getByTestId("workspace-pool-cny")).toHaveTextContent(
				"¥600.00",
			),
		);

		const callsBeforeUnmount = queryMock.mock.calls.length;
		unmount();
		await act(async () => {
			await vi.advanceTimersByTimeAsync(10_000);
		});
		expect(queryMock.mock.calls.length).toBe(callsBeforeUnmount);
	});

	it("渲染共享池账本流水，并支持按角色或指定成员派发", async () => {
		queryMock.mockImplementation(({ query }) => {
			if (query === WORKSPACE_LLM_POOL) {
				return Promise.resolve({ data: { workspaceLlmPool: POOL_FIXTURE } });
			}
			if (query === WORKSPACE_MEMBERS) {
				return Promise.resolve({
					data: {
						workspaceMembers: {
							count: 2,
							results: [
								{
									id: "mem-1",
									workspaceId: "ws-lab-1",
									userId: "user-tutor-1",
									userDisplayName: "林导师",
									userEmail: "tutor@example.com",
									roles: [{ id: "role-tutor", name: "tutor" }],
								},
								{
									id: "mem-2",
									workspaceId: "ws-lab-1",
									userId: "user-learner-1",
									userDisplayName: "张学员",
									userEmail: "learner@example.com",
									roles: [{ id: "role-learner", name: "learner" }],
								},
							],
						},
					},
				});
			}
			return Promise.resolve({ data: {} });
		});

		mutateMock.mockResolvedValue({
			data: {
				distributeWorkspaceLlmCredits: {
					id: "batch-targeted-1",
					perMemberMc: "5000000",
					memberCount: 1,
					totalGrantedMc: "5000000",
					idempotentReplay: false,
				},
			},
		});

		render(<WorkspaceLlmPoolPage />);

		const entriesTable = await screen.findByTestId(
			"workspace-pool-entries-table",
		);
		expect(within(entriesTable).getByText("订单充值")).toBeInTheDocument();
		expect(within(entriesTable).getByText("+¥100.00")).toBeInTheDocument();
		expect(within(entriesTable).getByText("批量派发扣减")).toBeInTheDocument();
		expect(within(entriesTable).getByText("-¥50.00")).toBeInTheDocument();

		const form = screen.getByTestId("workspace-distribute-form");
		fireEvent.change(within(form).getByPlaceholderText("10.00"), {
			target: { value: "5" },
		});

		// 按角色派发：未选角色先校验拦截，勾选 tutor 后正常提交
		fireEvent.click(screen.getByTestId("target-mode-roles"));
		fireEvent.submit(form);
		expect(
			await screen.findByText("请至少选择一个接收角色。"),
		).toBeInTheDocument();

		const roleSelector = screen.getByTestId("target-roles-selector");
		expect(within(roleSelector).queryByLabelText("admin")).not.toBeInTheDocument();
		expect(within(roleSelector).queryByLabelText("owner")).not.toBeInTheDocument();
		expect(within(roleSelector).getByLabelText("learner")).toBeInTheDocument();
		fireEvent.click(within(roleSelector).getByLabelText("tutor"));
		fireEvent.submit(form);

		await waitFor(() =>
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: DISTRIBUTE_WORKSPACE_LLM_CREDITS,
				variables: expect.objectContaining({
					workspaceId: "ws-lab-1",
					perMemberMc: "5000000",
					targetRoles: ["tutor"],
				}),
			}),
		);

		// 按指定成员派发
		fireEvent.click(screen.getByTestId("target-mode-members"));
		const memberSelector = await screen.findByTestId("target-members-selector");
		fireEvent.change(within(form).getByPlaceholderText("10.00"), {
			target: { value: "5" },
		});
		fireEvent.click(within(memberSelector).getByLabelText(/林导师/));
		fireEvent.submit(form);

		await waitFor(() =>
			expect(mutateMock).toHaveBeenLastCalledWith({
				mutation: DISTRIBUTE_WORKSPACE_LLM_CREDITS,
				variables: expect.objectContaining({
					workspaceId: "ws-lab-1",
					perMemberMc: "5000000",
					targetUserIds: ["user-tutor-1"],
				}),
			}),
		);
	});
});
