import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { createElement, type ReactNode } from "react";
import { render } from "@/test-utils";
import {
  OfferingDetailPage,
  OfferingsListPage,
  OfferingNewPage,
} from "./offering-pages";

const mocks = vi.hoisted(() => ({
  createOffering: vi.fn(),
  fetchOffering: vi.fn(),
  fetchMyEnrollment: vi.fn(),
  fetchPendingCount: vi.fn(),
  fetchWorkspaceOfferings: vi.fn(),
  transitionOffering: vi.fn(),
  updateOffering: vi.fn(),
  useWorkspaceBySlug: vi.fn(),
}));

const routerMocks = vi.hoisted(() => ({ push: vi.fn(), replace: vi.fn() }));

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
    status === "draft"
      ? ["launch"]
      : status === "open"
        ? ["close", "cancel"]
        : [],
  canManageEvents: (roleNames: string[] = []) =>
    roleNames.some((role) => role === "owner" || role === "admin"),
  createOffering: mocks.createOffering,
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
  default: ({ children }: { children: ReactNode }) =>
    createElement("main", null, children),
}));

vi.mock("@/components/invite-batch-panel", () => ({
  default: () => null,
}));

vi.mock("@/components/event-status-tag", () => ({
  default: ({ status }: { status: string }) =>
    createElement("span", null, status),
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

const { submitEnrollment } = vi.hoisted(() => ({ submitEnrollment: vi.fn() }));

vi.mock("@/lib/public-offerings", () => ({
  parseSponsorshipTiers: () => [],
  submitEnrollment,
}));

vi.mock("next/link", () => ({
  default: ({ href, children }: { href: string; children: ReactNode }) =>
    createElement("a", { href }, children),
}));

vi.mock("next/navigation", () => ({
  usePathname: () => "/w/demo/events",
  useRouter: () => routerMocks,
}));

const WORKSPACE = {
  id: "workspace-1",
  slug: "demo",
  name: "测试工作台",
  joinPolicy: "open" as const,
  sponsorshipEnabled: false,
  myRoleNames: [],
};

const OWNER_WORKSPACE = { ...WORKSPACE, myRoleNames: ["owner"] };

function offeringRow(overrides: Record<string, unknown> = {}) {
  return {
    id: "offering-1",
    workspaceId: "workspace-1",
    title: "测试活动",
    slug: null,
    status: "draft",
    visibility: "public",
    enrollmentPolicy: "open",
    capacity: null,
    confirmedCount: 0,
    registrationDeadline: null,
    ...overrides,
  };
}

/** manage（Owner）视角渲染详情页，返回 heading 就绪 promise */
function renderManageDetail(
  kind: "event" | "course",
  row: Record<string, unknown>,
) {
  mocks.useWorkspaceBySlug.mockReturnValue({
    ws: OWNER_WORKSPACE,
    readOnlyVisitor: false,
    loading: false,
    error: null,
    retry: vi.fn(),
  });
  mocks.fetchOffering.mockResolvedValueOnce(row);
  render(<OfferingDetailPage slug="demo" id={String(row.id)} kind={kind} />);
  return screen.findByRole("heading", { name: String(row.title) });
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.fetchMyEnrollment.mockResolvedValue(null);
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

    expect(
      await screen.findByRole("heading", { name: label }),
    ).toBeInTheDocument();
    expect(screen.queryByText(/草稿/)).not.toBeInTheDocument();
    expect(screen.getByText(new RegExp(`${label}与报名`))).toBeInTheDocument();
  });
});

describe("OfferingDetailPage 错误态", () => {
  it("offering null 渲染不可访问文案，而非永久 skeleton", async () => {
    mocks.fetchOffering.mockResolvedValueOnce(null);

    render(<OfferingDetailPage slug="demo" id="missing-event" kind="event" />);

    expect(
      await screen.findByRole("heading", { name: "该活动不可访问或不存在" }),
    ).toBeInTheDocument();
    expect(screen.getByText(/仅工作台内部可见，或已结束/)).toBeInTheDocument();
    expect(document.querySelector(".animate-pulse")).not.toBeInTheDocument();
  });

  it("网络错误不渲染 raw GraphQL message", async () => {
    mocks.fetchOffering.mockRejectedValueOnce(
      new Error("Cannot query field getEvent"),
    );

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

    expect(
      await screen.findByRole("heading", { name: "公开活动" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "报名" }),
    ).not.toBeInTheDocument();
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

    const { rerender } = render(
      <OfferingDetailPage slug="demo" id="event-open" kind="event" />,
    );

    // offering 已加载而 hook 仍在 loading：CTA 不得闪现
    expect(
      await screen.findByRole("heading", { name: "公开活动" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "报名" }),
    ).not.toBeInTheDocument();

    // fallback settle：仍不渲染
    rerender(<OfferingDetailPage slug="demo" id="event-open" kind="event" />);
    expect(
      screen.queryByRole("button", { name: "报名" }),
    ).not.toBeInTheDocument();
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

    expect(
      await screen.findByRole("button", { name: "报名" }),
    ).toBeInTheDocument();
  });

  it("终态报名不挡再报名：fetchMyEnrollment=false（查询已滤终态）→ 渲染报名按钮（e2e #2）", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue({
      ws: WORKSPACE,
      readOnlyVisitor: false,
      loading: false,
      error: null,
      retry: vi.fn(),
    });
    mocks.fetchOffering.mockResolvedValueOnce({
      id: "event-cancelled-enr",
      title: "已取消报名活动",
      status: "open",
      visibility: "workspace",
      enrollmentPolicy: "open",
      registrationDeadline: null,
      capacity: null,
      confirmedCount: 0,
    });
    // 后端存在 cancelled 终态行，但活跃态过滤后查询返回空 → 无活跃报名
    mocks.fetchMyEnrollment.mockResolvedValueOnce(null);

    render(
      <OfferingDetailPage slug="demo" id="event-cancelled-enr" kind="event" />,
    );

    expect(
      await screen.findByRole("button", { name: "报名" }),
    ).toBeInTheDocument();
    expect(screen.queryByText(/你已报名该活动/)).not.toBeInTheDocument();
    await waitFor(() =>
      expect(mocks.fetchMyEnrollment).toHaveBeenCalledWith(
        "event-cancelled-enr",
        "event",
        "user-1",
      ),
    );
  });

  it("免费活动（pricingEnabled 缺省）：不渲染档位选择器（R4 零变化）", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue({
      ws: WORKSPACE,
      readOnlyVisitor: false,
      loading: false,
      error: null,
      retry: vi.fn(),
    });
    mocks.fetchOffering.mockResolvedValueOnce({
      id: "event-free",
      title: "免费活动",
      status: "open",
      visibility: "workspace",
      enrollmentPolicy: "open",
      registrationDeadline: null,
      capacity: null,
      confirmedCount: 0,
    });

    render(<OfferingDetailPage slug="demo" id="event-free" kind="event" />);

    expect(
      await screen.findByRole("button", { name: "报名" }),
    ).toBeInTheDocument();
    expect(screen.queryByTestId("price-tier-picker")).not.toBeInTheDocument();
  });

  it("收费活动：渲染可售档位 + 未选档提交被拒 + 选档后 tierId 随报名提交", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue({
      ws: WORKSPACE,
      readOnlyVisitor: false,
      loading: false,
      error: null,
      retry: vi.fn(),
    });
    mocks.fetchOffering.mockResolvedValueOnce({
      id: "event-paid",
      title: "收费活动",
      status: "open",
      visibility: "workspace",
      enrollmentPolicy: "open",
      registrationDeadline: null,
      capacity: null,
      confirmedCount: 0,
      pricingEnabled: true,
      availablePriceTiers: [
        JSON.stringify({ id: "tier-1", name: "早鸟", amount_cents: 9900 }),
        JSON.stringify({ id: "tier-2", name: "标准", amount_cents: 19900 }),
      ],
    });

    submitEnrollment.mockResolvedValueOnce({
      result: { id: "enr-1", status: "payment_pending" },
      errors: [],
    });

    render(<OfferingDetailPage slug="demo" id="event-paid" kind="event" />);

    // 档位渲染（价格格式化）
    const picker = await screen.findByTestId("price-tier-picker");
    expect(picker).toBeInTheDocument();
    expect(screen.getByText("¥99.00")).toBeInTheDocument();
    expect(screen.getByText("¥199.00")).toBeInTheDocument();

    // 未选档 → 前端拒绝，不触 mutation
    fireEvent.click(screen.getByRole("button", { name: "报名" }));
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "请先选择价格档位",
    );
    expect(submitEnrollment).not.toHaveBeenCalled();

    // 选档（radio）→ 提交携带 tierId；payment_pending 态自动弹收银模态框
    fireEvent.click(screen.getByTestId("price-tier-tier-2"));
    fireEvent.click(screen.getByRole("button", { name: "报名并支付 ¥199.00" }));

    await waitFor(() => expect(submitEnrollment).toHaveBeenCalledTimes(1));
    expect(submitEnrollment).toHaveBeenCalledWith(
      expect.objectContaining({ tierId: "tier-2", eventId: "event-paid" }),
    );

    expect(await screen.findByTestId("checkout-dialog")).toBeInTheDocument();
  });
});

describe("OfferingDetailPage 报名状态分叉（支付接续）", () => {
  function renderOpen() {
    mocks.useWorkspaceBySlug.mockReturnValue({
      ws: WORKSPACE,
      readOnlyVisitor: false,
      loading: false,
      error: null,
      retry: vi.fn(),
    });
    mocks.fetchOffering.mockResolvedValueOnce({
      id: "event-open",
      title: "开放活动",
      status: "open",
      visibility: "workspace",
      enrollmentPolicy: "open",
      registrationDeadline: null,
      capacity: null,
      confirmedCount: 0,
    });
    render(<OfferingDetailPage slug="demo" id="event-open" kind="event" />);
  }

  it("payment_pending 既有报名 → 待支付卡（名额已保留 + 继续支付开收银模态框），不渲染报名表单", async () => {
    mocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-pending",
      status: "payment_pending",
    });

    renderOpen();

    expect(
      await screen.findByTestId("enrollment-pending-card"),
    ).toBeInTheDocument();
    expect(screen.getByText(/名额已保留/)).toBeInTheDocument();
    // 批①桌面：继续支付入口开收银模态框（不再跳 /orders/new）
    fireEvent.click(screen.getByTestId("enrollment-pending-pay"));
    expect(await screen.findByTestId("checkout-dialog")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "报名" }),
    ).not.toBeInTheDocument();
  });

  it("confirmed 既有报名 → 你已报名，不渲染报名表单", async () => {
    mocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-confirmed",
      status: "confirmed",
    });

    renderOpen();

    expect(await screen.findByText("你已报名该活动。")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "报名" }),
    ).not.toBeInTheDocument();
  });

  it("pending 既有报名 → 审批中文案，不渲染报名表单", async () => {
    mocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-pending-req",
      status: "pending",
    });

    renderOpen();

    expect(await screen.findByText(/申请审批中/)).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "报名" }),
    ).not.toBeInTheDocument();
  });
});

describe("OfferingNewPage 新建调用链", () => {
  it.each([
    ["event", "活动", "/w/demo/events/"],
    ["course", "课程", "/w/demo/courses/"],
  ] as const)(
    "%s 填表提交 → createOffering 变量正确 → 跳转详情路由",
    async (kind, label, base) => {
      mocks.useWorkspaceBySlug.mockReturnValue({
        ws: OWNER_WORKSPACE,
        readOnlyVisitor: false,
        loading: false,
        error: null,
        retry: vi.fn(),
      });
      mocks.createOffering.mockResolvedValueOnce({
        result: {
          id: "offering-1",
          title: "春季训练营",
          status: "draft",
          visibility: "workspace",
          enrollmentPolicy: "request",
          capacity: 20,
          confirmedCount: 0,
          registrationDeadline: null,
        },
        errors: [],
      });

      render(<OfferingNewPage slug="demo" kind={kind} />);

      fireEvent.change(await screen.findByLabelText(/标题/), {
        target: { value: "春季训练营" },
      });
      fireEvent.change(screen.getByLabelText("报名策略"), {
        target: { value: "request" },
      });
      fireEvent.click(screen.getByRole("button", { name: "仅工作台可见" }));
      fireEvent.change(screen.getByLabelText(/名额上限/), {
        target: { value: "20" },
      });
      fireEvent.change(screen.getByLabelText(/报名截止/), {
        target: { value: "2026-12-31T23:59" },
      });
      fireEvent.click(screen.getByRole("button", { name: `创建${label}` }));

      await waitFor(() =>
        expect(mocks.createOffering).toHaveBeenCalledWith("workspace-1", kind, {
          title: "春季训练营",
          enrollmentPolicy: "request",
          visibility: "workspace",
          capacity: 20,
          registrationDeadline: new Date("2026-12-31T23:59").toISOString(),
        }),
      );
      expect(routerMocks.push).toHaveBeenCalledWith(`${base}offering-1`);
    },
  );

  it.each(["event", "course"] as const)(
    "%s 非管理成员渲染拦回且不调用 createOffering",
    async (kind) => {
      mocks.useWorkspaceBySlug.mockReturnValue({
        ws: WORKSPACE,
        readOnlyVisitor: false,
        loading: false,
        error: null,
        retry: vi.fn(),
      });

      render(<OfferingNewPage slug="demo" kind={kind} />);

      expect(
        await screen.findByText(/仅 Owner\/Admin 可创建/),
      ).toBeInTheDocument();
      expect(mocks.createOffering).not.toHaveBeenCalled();
      expect(routerMocks.push).not.toHaveBeenCalled();
    },
  );

  it.each([
    ["event", "活动"],
    ["course", "课程"],
  ] as const)(
    "%s 创建失败：错误展示且 busy 复位、不跳转",
    async (kind, label) => {
      mocks.useWorkspaceBySlug.mockReturnValue({
        ws: OWNER_WORKSPACE,
        readOnlyVisitor: false,
        loading: false,
        error: null,
        retry: vi.fn(),
      });
      mocks.createOffering.mockRejectedValueOnce(new Error("创建失败"));

      render(<OfferingNewPage slug="demo" kind={kind} />);

      fireEvent.change(await screen.findByLabelText(/标题/), {
        target: { value: "春季训练营" },
      });
      fireEvent.click(screen.getByRole("button", { name: `创建${label}` }));

      expect(await screen.findByText("创建失败")).toBeInTheDocument();
      expect(
        screen.getByRole("button", { name: `创建${label}` }),
      ).not.toBeDisabled();
      expect(routerMocks.push).not.toHaveBeenCalled();
    },
  );
});

describe("OfferingDetailPage 保存元数据调用链", () => {
  it.each(["event", "course"] as const)(
    "%s 改元数据 → updateOffering 变量正确 → 表单复位",
    async (kind) => {
      mocks.updateOffering.mockResolvedValueOnce({
        result: {
          id: "offering-1",
          title: "新标题",
          status: "draft",
          visibility: "public",
          enrollmentPolicy: "request",
          capacity: 20,
          registrationDeadline: new Date("2026-12-31T23:59").toISOString(),
        },
        errors: [],
      });

      await renderManageDetail(kind, offeringRow({}));

      fireEvent.change(screen.getByLabelText("标题"), {
        target: { value: "新标题" },
      });
      fireEvent.change(screen.getByLabelText("报名策略"), {
        target: { value: "request" },
      });
      fireEvent.change(screen.getByLabelText(/名额上限/), {
        target: { value: "20" },
      });
      fireEvent.change(screen.getByLabelText(/报名截止/), {
        target: { value: "2026-12-31T23:59" },
      });
      fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

      await waitFor(() =>
        expect(mocks.updateOffering).toHaveBeenCalledWith("offering-1", kind, {
          title: "新标题",
          enrollmentPolicy: "request",
          capacity: 20,
          registrationDeadline: new Date("2026-12-31T23:59").toISOString(),
          ...(kind === "course"
            ? { researchRequirements: JSON.stringify({ note: "" }) }
            : {}),
        }),
      );
      // 成功：局部状态更新（标题）＋表单复位（metaDraft → null）
      expect(
        await screen.findByRole("heading", { name: "新标题" }),
      ).toBeInTheDocument();
      expect(screen.getByText("已保存")).toBeInTheDocument();
      expect(
        screen.getByRole("button", { name: "保存元数据" }),
      ).not.toBeDisabled();
    },
  );

  it.each(["event", "course"] as const)(
    "%s 名额非法 → 映射文案，不透传 GraphQL 原文",
    async (kind) => {
      mocks.updateOffering.mockResolvedValueOnce({
        result: null,
        errors: [
          {
            message: "Input is invalid",
            short_message: "capacity must be greater than or equal to 1",
          },
        ],
      });

      await renderManageDetail(kind, offeringRow({}));

      fireEvent.change(screen.getByLabelText(/名额上限/), {
        target: { value: "0" },
      });
      fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

      expect(
        await screen.findByText("保存失败：名额上限需大于等于 1。"),
      ).toBeInTheDocument();
      expect(screen.queryByText(/Input is invalid/)).not.toBeInTheDocument();
      expect(screen.queryByText(/capacity must/)).not.toBeInTheDocument();
      expect(
        screen.getByRole("button", { name: "保存元数据" }),
      ).not.toBeDisabled();
    },
  );

  it("未知错误（网络异常）走兜底文案，不透传原始 message", async () => {
    mocks.updateOffering.mockRejectedValueOnce(
      new Error("Network request failed"),
    );

    await renderManageDetail("event", offeringRow({}));

    fireEvent.change(screen.getByLabelText("标题"), { target: { value: "x" } });
    fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

    expect(await screen.findByText("保存失败，请重试")).toBeInTheDocument();
    expect(
      screen.queryByText(/Network request failed/),
    ).not.toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "保存元数据" }),
    ).not.toBeDisabled();
  });
});

describe("OfferingDetailPage 可见性双向切换（D9）", () => {
  it.each([
    ["workspace", "公开可见", "public"],
    ["public", "仅工作台可见", "workspace"],
  ] as const)(
    "open 状态 %s → %s：updateOffering 仅 visibility 变量",
    async (from, targetLabel, next) => {
      mocks.updateOffering.mockResolvedValueOnce({
        result: {
          id: "offering-1",
          title: "测试活动",
          status: "open",
          visibility: next,
          enrollmentPolicy: "open",
          capacity: null,
          registrationDeadline: null,
        },
        errors: [],
      });

      await renderManageDetail(
        "event",
        offeringRow({ status: "open", visibility: from }),
      );

      fireEvent.click(screen.getByRole("button", { name: targetLabel }));

      await waitFor(() =>
        expect(mocks.updateOffering).toHaveBeenCalledWith(
          "offering-1",
          "event",
          {
            visibility: next,
          },
        ),
      );
      // 保存成功后目标按钮成为当前可见性（disabled 选中态）
      expect(screen.getByRole("button", { name: targetLabel })).toBeDisabled();
    },
  );
});

describe("OfferingDetailPage 生命周期调用链", () => {
  it.each(["event", "course"] as const)(
    "%s draft → launch：直达无确认 → open 状态更新",
    async (kind) => {
      mocks.transitionOffering.mockResolvedValueOnce({
        result: { id: "offering-1", status: "open" },
        errors: [],
      });

      await renderManageDetail(kind, offeringRow({}));

      fireEvent.click(screen.getByRole("button", { name: "发布（开放报名）" }));

      await waitFor(() =>
        expect(mocks.transitionOffering).toHaveBeenCalledWith(
          "offering-1",
          kind,
          "launch",
        ),
      );
      // launch 无确认条（确认按钮角色不出现）
      expect(
        screen.queryByRole("button", { name: /^确认/ }),
      ).not.toBeInTheDocument();
      // 局部状态更新：徽章 open，按钮切换为 close/cancel
      expect(await screen.findByText("open")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "结束" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "取消" })).toBeInTheDocument();
    },
  );

  it.each(["event", "course"] as const)(
    "%s open → close：确认条 → 二次确认 → closed 终态无按钮",
    async (kind) => {
      mocks.transitionOffering.mockResolvedValueOnce({
        result: { id: "offering-1", status: "closed" },
        errors: [],
      });

      await renderManageDetail(kind, offeringRow({ status: "open" }));

      fireEvent.click(screen.getByRole("button", { name: "结束" }));
      // 一次点击只出确认条，不执行 mutation
      expect(mocks.transitionOffering).not.toHaveBeenCalled();
      expect(screen.getByText(/确认结束该/)).toBeInTheDocument();

      fireEvent.click(screen.getByRole("button", { name: "确认结束" }));

      await waitFor(() =>
        expect(mocks.transitionOffering).toHaveBeenCalledWith(
          "offering-1",
          kind,
          "close",
        ),
      );
      expect(await screen.findByText("closed")).toBeInTheDocument();
      expect(
        screen.queryByRole("button", { name: "结束" }),
      ).not.toBeInTheDocument();
      expect(
        screen.queryByRole("button", { name: "取消" }),
      ).not.toBeInTheDocument();
      expect(screen.queryByText(/确认结束该/)).not.toBeInTheDocument();
      expect(screen.getByText(/终态/)).toBeInTheDocument();
    },
  );

  it.each(["event", "course"] as const)(
    "%s open → cancel：确认条 → 二次确认 → cancelled 终态无按钮",
    async (kind) => {
      mocks.transitionOffering.mockResolvedValueOnce({
        result: { id: "offering-1", status: "cancelled" },
        errors: [],
      });

      await renderManageDetail(kind, offeringRow({ status: "open" }));

      fireEvent.click(screen.getByRole("button", { name: "取消" }));
      expect(mocks.transitionOffering).not.toHaveBeenCalled();
      expect(screen.getByText(/确认取消该/)).toBeInTheDocument();

      fireEvent.click(screen.getByRole("button", { name: "确认取消" }));

      await waitFor(() =>
        expect(mocks.transitionOffering).toHaveBeenCalledWith(
          "offering-1",
          kind,
          "cancel",
        ),
      );
      expect(await screen.findByText("cancelled")).toBeInTheDocument();
      expect(
        screen.queryByRole("button", { name: "结束" }),
      ).not.toBeInTheDocument();
      expect(
        screen.queryByRole("button", { name: "取消" }),
      ).not.toBeInTheDocument();
      expect(screen.getByText(/终态/)).toBeInTheDocument();
    },
  );

  it("确认条可返回：不执行 mutation，恢复原按钮", async () => {
    await renderManageDetail("event", offeringRow({ status: "open" }));

    fireEvent.click(screen.getByRole("button", { name: "结束" }));
    fireEvent.click(screen.getByRole("button", { name: "返回" }));

    expect(mocks.transitionOffering).not.toHaveBeenCalled();
    expect(screen.queryByText(/确认结束/)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "结束" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "取消" })).toBeInTheDocument();
  });

  it.each(["event", "course"] as const)(
    "%s transition 失败：映射文案 + busy 复位 + 确认条保留可重试",
    async (kind) => {
      mocks.transitionOffering.mockResolvedValueOnce({
        result: null,
        errors: [
          {
            message:
              "close failed: status changed concurrently, retry on fresh read",
          },
        ],
      });

      await renderManageDetail(kind, offeringRow({ status: "open" }));

      fireEvent.click(screen.getByRole("button", { name: "结束" }));
      fireEvent.click(screen.getByRole("button", { name: "确认结束" }));

      expect(
        await screen.findByText(
          "操作失败：状态已被其他操作变更，请刷新后重试。",
        ),
      ).toBeInTheDocument();
      expect(
        screen.queryByText(/status changed concurrently/),
      ).not.toBeInTheDocument();
      expect(
        screen.getByRole("button", { name: "确认结束" }),
      ).not.toBeDisabled();
    },
  );
});

describe("OfferingDetailPage fetchPendingCount 权限门控", () => {
  it("manage 视角发起 fetchPendingCount", async () => {
    await renderManageDetail("event", offeringRow({}));

    await waitFor(() =>
      expect(mocks.fetchPendingCount).toHaveBeenCalledWith(
        "offering-1",
        "event",
      ),
    );
  });

  it("普通成员不发 fetchPendingCount", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue({
      ws: WORKSPACE,
      readOnlyVisitor: false,
      loading: false,
      error: null,
      retry: vi.fn(),
    });
    mocks.fetchOffering.mockResolvedValueOnce(offeringRow({}));

    render(<OfferingDetailPage slug="demo" id="offering-1" kind="event" />);

    await screen.findByRole("heading", { name: "测试活动" });
    expect(mocks.fetchPendingCount).not.toHaveBeenCalled();
  });
});
