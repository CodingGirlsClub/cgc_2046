import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import {
	deriveInviteBatchDisplayStatus,
	inviteBatchBadgeClass,
	type InviteBatchPanelProps,
} from "./invite-batch-panel";
import type { InviteBatchItem } from "@/lib/graphql/invite-batch";
import InviteBatchPanel from "./invite-batch-panel";

type GraphqlDocument = {
	definitions?: Array<{ name?: { value?: string } }>;
};

const { useQuery, useMutation, refetch } = vi.hoisted(() => ({
	useQuery: vi.fn(),
	useMutation: vi.fn(),
	refetch: vi.fn(),
}));
const { copyText } = vi.hoisted(() => ({ copyText: vi.fn() }));
const { createMutate, disableMutate } = vi.hoisted(() => ({
	createMutate: vi.fn(),
	disableMutate: vi.fn(),
}));

vi.mock("@apollo/client/react", () => ({ useQuery, useMutation }));
vi.mock("@/lib/clipboard", () => ({ copyText }));

const ACTIVE_ITEM: InviteBatchItem = {
	id: "batch-active",
	workspaceId: "ws-1",
	eventId: "event-1",
	courseId: null,
	inviteCode: "ACTIVE1234",
	quota: 4,
	remainingQuota: 3,
	expiresAt: "2099-01-01T00:00:00Z",
	status: "active" as const,
	remark: "早鸟",
	insertedAt: "2026-08-15T00:00:00Z",
};

const DISABLED_ITEM = {
	...ACTIVE_ITEM,
	id: "batch-disabled",
	inviteCode: "DISABLED123",
	status: "disabled" as const,
};

const EXPIRED_ITEM = {
	...ACTIVE_ITEM,
	id: "batch-expired",
	inviteCode: "EXPIRED1234",
	expiresAt: "2020-01-01T00:00:00Z",
};

const EXHAUSTED_ITEM = {
	...ACTIVE_ITEM,
	id: "batch-exhausted",
	inviteCode: "EXHAUSTED1",
	remainingQuota: 0,
};

let queryResult: Record<string, unknown>;

function setQuery(
	rows = [ACTIVE_ITEM],
	options: { loading?: boolean; error?: Error; endKeyset?: string | null } = {},
) {
	queryResult = {
		data: {
			inviteBatches: {
				results: rows,
				endKeyset: options.endKeyset ?? null,
			},
		},
		loading: options.loading ?? false,
		error: options.error,
		refetch,
	};
	useQuery.mockImplementation(() => queryResult);
}

function mockMutations() {
	useMutation.mockImplementation((document: GraphqlDocument) => {
		const name = document.definitions?.[0]?.name?.value ?? "";
		return name === "CreateInviteBatch"
			? [createMutate, { loading: false }]
			: [disableMutate, { loading: false }];
	});
}

function renderPanel(props: Partial<InviteBatchPanelProps> = {}) {
	return render(
		<InviteBatchPanel
			kind="event"
			offeringId="event-1"
			offeringStatus="open"
			workspaceId="ws-1"
			{...props}
		/>,
	);
}

beforeEach(() => {
	vi.clearAllMocks();
	refetch.mockResolvedValue({
		data: { inviteBatches: { results: [ACTIVE_ITEM], endKeyset: null } },
	});
	setQuery();
	mockMutations();
	copyText.mockResolvedValue(true);
	createMutate.mockResolvedValue({
		data: { createInviteBatch: { result: ACTIVE_ITEM, errors: [] } },
	});
	disableMutate.mockResolvedValue({
		data: { disableInviteBatch: { result: { ...ACTIVE_ITEM, status: "disabled" }, errors: [] } },
	});
});

afterEach(cleanup);

describe("InviteBatch 状态派生", () => {
	it("按 disabled > expired > exhausted > active 优先级派生并映射徽章", () => {
		const now = Date.parse("2026-08-15T00:00:00Z");

		expect(deriveInviteBatchDisplayStatus(ACTIVE_ITEM, now)).toBe("active");
		expect(deriveInviteBatchDisplayStatus(EXHAUSTED_ITEM, now)).toBe("exhausted");
		expect(deriveInviteBatchDisplayStatus(EXPIRED_ITEM, now)).toBe("expired");
		expect(deriveInviteBatchDisplayStatus(DISABLED_ITEM, now)).toBe("disabled");
		expect(inviteBatchBadgeClass("active")).toContain("l-badge-success");
		expect(inviteBatchBadgeClass("exhausted")).toContain("l-badge-muted");
	});
});

describe("InviteBatchPanel 列表", () => {
	it("覆盖 loading、error + 重试、空态三分支", async () => {
		setQuery([], { loading: true });
		const { unmount } = renderPanel();
		expect(screen.getByText("加载中…")).toBeInTheDocument();
		unmount();

		setQuery([], { error: new Error("network down") });
		renderPanel();
		expect(screen.getByRole("alert")).toHaveTextContent("network down");
		fireEvent.click(screen.getByRole("button", { name: "重试" }));
		await waitFor(() => expect(refetch).toHaveBeenCalledWith({
			filter: { workspaceId: { eq: "ws-1" }, eventId: { eq: "event-1" } },
			first: 50,
			after: null,
		}));
		cleanup();

		setQuery([]);
		renderPanel();
		expect(await screen.findByText("暂无批次码")).toBeInTheDocument();
	});

	it("将四种行状态映射到对应徽章，并保留可复制邀请码", async () => {
		setQuery([ACTIVE_ITEM, DISABLED_ITEM, EXPIRED_ITEM, EXHAUSTED_ITEM]);
		renderPanel();

		expect(await screen.findByText("ACTIVE1234")).toBeInTheDocument();
		expect(screen.getAllByText("有效")).toHaveLength(1);
		expect(screen.getAllByText("已禁用")).toHaveLength(1);
		expect(screen.getAllByText("已过期")).toHaveLength(1);
		expect(screen.getAllByText("已用尽")).toHaveLength(1);
		expect(screen.getAllByRole("button", { name: "复制邀请码" })).toHaveLength(4);
		expect(screen.getAllByText(/已使用\s*1\s*\/\s*4\s*人/)).toHaveLength(3);
	});
	it("加载更多携带 workspace/offering filter、first=50 和 endKeyset 游标并追加", async () => {
		setQuery([ACTIVE_ITEM], { endKeyset: "cursor-1" });
		refetch.mockResolvedValueOnce({
			data: {
				inviteBatches: {
					results: [{ ...ACTIVE_ITEM, id: "batch-next", inviteCode: "NEXT123456" }],
					endKeyset: null,
				},
			},
		});
		renderPanel();
		await screen.findByText("ACTIVE1234");
		fireEvent.click(screen.getByRole("button", { name: "加载更多" }));

		await waitFor(() => expect(refetch).toHaveBeenCalledWith({
			filter: { workspaceId: { eq: "ws-1" }, eventId: { eq: "event-1" } },
			first: 50,
			after: "cursor-1",
		}));
		expect(await screen.findByText("NEXT123456")).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "加载更多" })).not.toBeInTheDocument();
	});
});

describe("InviteBatchPanel 创建", () => {
	it("生成 10 位合法邀请码，并提交 eventId、UTC 过期时间和备注后刷新列表", async () => {
		renderPanel();
		await screen.findByText("ACTIVE1234");
		fireEvent.click(screen.getByRole("button", { name: "生成" }));
		const generated = screen.getByLabelText("邀请码");
		expect(generated).toHaveDisplayValue(/^[A-Za-z0-9]{10}$/);
		fireEvent.change(screen.getByLabelText("邀请码"), { target: { value: "NEWCODE01" } });
		fireEvent.change(screen.getByLabelText("配额"), { target: { value: "3" } });
		fireEvent.change(screen.getByLabelText("过期时间（可选）"), {
			target: { value: "2099-01-02T10:30" },
		});
		fireEvent.change(screen.getByLabelText("备注（可选）"), { target: { value: "春季招募" } });
		fireEvent.click(screen.getByRole("button", { name: "创建批次码" }));

		await waitFor(() => expect(createMutate).toHaveBeenCalledWith({
			variables: {
				input: {
					eventId: "event-1",
					inviteCode: "NEWCODE01",
					quota: 3,
					expiresAt: new Date("2099-01-02T10:30").toISOString(),
					remark: "春季招募",
				},
			},
		}));
		await waitFor(() => expect(refetch).toHaveBeenCalled());
		expect(await screen.findByText("批次码已创建")).toBeInTheDocument();
	});

	it("重复码映射为全平台唯一的表单级错误，过去时间不发 mutation", async () => {
		createMutate.mockResolvedValueOnce({
			data: {
				createInviteBatch: {
					result: null,
					errors: [{ message: "invite_code has already been taken" }],
				},
			},
		});
		renderPanel();
		await screen.findByText("ACTIVE1234");
		fireEvent.change(screen.getByLabelText("邀请码"), { target: { value: "DUPLICATE" } });
		fireEvent.click(screen.getByRole("button", { name: "创建批次码" }));
		expect(await screen.findByRole("alert")).toHaveTextContent("全平台唯一");

		fireEvent.change(screen.getByLabelText("过期时间（可选）"), {
			target: { value: "2020-01-01T10:30" },
		});
		fireEvent.click(screen.getByRole("button", { name: "创建批次码" }));
		expect(await screen.findByText("过期时间必须晚于当前时间")).toBeInTheDocument();
		expect(createMutate).toHaveBeenCalledTimes(1);
	});

	it("非 open 活动禁用创建表单并显示原因", async () => {
		renderPanel({ offeringStatus: "closed" });
		expect(await screen.findByText("活动当前状态不可创建批次码")).toBeInTheDocument();
		expect(screen.getByLabelText("邀请码")).toBeDisabled();
		expect(screen.getByRole("button", { name: "生成" })).toBeDisabled();
		expect(screen.getByRole("button", { name: "创建批次码" })).toBeDisabled();
	});
});

describe("InviteBatchPanel 禁用与复制", () => {
	it("复制成功提示；失败保留可选文本并显示手动复制降级提示", async () => {
		renderPanel();
		await screen.findByText("ACTIVE1234");
		fireEvent.click(screen.getByRole("button", { name: "复制邀请码" }));
		expect(await screen.findByText("已复制")).toBeInTheDocument();

		cleanup();
		copyText.mockResolvedValue(false);
		renderPanel();
		await screen.findByText("ACTIVE1234");
		fireEvent.click(screen.getByRole("button", { name: "复制邀请码" }));
		expect(await screen.findByText("请手动复制邀请码")).toBeInTheDocument();
		expect(screen.getByText("ACTIVE1234")).toHaveClass("select-text");
	});

	it("确认后提交中锁定；成功刷新为 disabled", async () => {
		const deferred = Promise.withResolvers<unknown>();
		disableMutate.mockReturnValueOnce(deferred.promise);
		refetch.mockResolvedValueOnce({
			data: {
				inviteBatches: {
					results: [{ ...ACTIVE_ITEM, status: "disabled" }],
					endKeyset: null,
				},
			},
		});
		renderPanel();
		await screen.findByText("ACTIVE1234");
		fireEvent.click(screen.getByRole("button", { name: "禁用" }));
		expect(screen.getByText(/配额将作废/)).toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: "确认禁用" }));
		await waitFor(() => expect(disableMutate).toHaveBeenCalledWith({ variables: { id: "batch-active" } }));
		expect(screen.getByRole("button", { name: "提交中…" })).toBeDisabled();

		deferred.resolve({
			data: { disableInviteBatch: { result: { ...ACTIVE_ITEM, status: "disabled" }, errors: [] } },
		});
		expect(await screen.findByText("已禁用")).toBeInTheDocument();
	});

	it("取消不发请求；禁用失败保留 active 并提供行级重试", async () => {
		disableMutate.mockResolvedValueOnce({
			data: { disableInviteBatch: { result: null, errors: [{ message: "forbidden" }] } },
		});
		renderPanel();
		await screen.findByText("ACTIVE1234");
		fireEvent.click(screen.getByRole("button", { name: "禁用" }));
		fireEvent.click(screen.getByRole("button", { name: "取消" }));
		expect(disableMutate).not.toHaveBeenCalled();

		fireEvent.click(screen.getByRole("button", { name: "禁用" }));
		fireEvent.click(screen.getByRole("button", { name: "确认禁用" }));
		expect(await screen.findByRole("alert")).toHaveTextContent("forbidden");
		expect(screen.getByText("有效")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "重试禁用" })).toBeInTheDocument();
	});
});
