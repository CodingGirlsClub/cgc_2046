import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
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
  fetchMyActiveEnrollments: vi.fn(),
  fetchMyEnrollment: vi.fn(),
  fetchPendingCount: vi.fn(),
  fetchWorkspaceOfferings: vi.fn(),
  transitionOffering: vi.fn(),
  updateOffering: vi.fn(),
  useWorkspaceBySlug: vi.fn(),
}));

const { client: apolloClient } = vi.hoisted(() => ({
  client: { query: vi.fn(), mutate: vi.fn() },
}));

vi.mock("@/lib/apollo-client", () => ({ client: apolloClient }));
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
  canManageEvents: (myAbilities: string[] = []) =>
    myAbilities.includes("manage_events"),
  createOffering: mocks.createOffering,
  fetchMyActiveEnrollments: mocks.fetchMyActiveEnrollments,
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

// 可变的登录态（未登录分支用）；beforeEach 复位为已登录
const authState = vi.hoisted(() => ({
  current: { authed: true, confirmed: true, userId: "user-1" as string | null },
}));
vi.mock("@/lib/use-authed", () => ({
  useAuthed: () => authState.current,
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

vi.mock("@/components/offering-payments-panel", () => ({
  default: () => null,
}));
vi.mock("@/components/speaker-invitation-panel", () => ({
  default: () => null,
}));

vi.mock("@/components/icons", () => ({
  Icon: () => null,
}));

const { submitEnrollment } = vi.hoisted(() => ({ submitEnrollment: vi.fn() }));

vi.mock("@/lib/public-offerings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/public-offerings")>()),
  parseSponsorshipTiers: () => [],
  submitEnrollment,
}));

vi.mock("next/link", () => ({
  default: ({ href, children, ...rest }: { href: string; children: ReactNode }) =>
    createElement("a", { href, ...rest }, children),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
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
  myAbilities: [],
};

const OWNER_WORKSPACE = {
  ...WORKSPACE,
  myRoleNames: ["owner"],
  myAbilities: [
    "view_workspace",
    "access_invite_only",
    "list_members",
    "manage_members",
    "assign_roles",
    "update_join_policy",
    "manage_events",
  ],
};

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
  authState.current = { authed: true, confirmed: true, userId: "user-1" };
  mocks.fetchMyActiveEnrollments.mockResolvedValue([]);
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

describe("OfferingsListPage 个人报名状态", () => {
  const COURSE_A = {
    id: "course-a",
    workspaceId: "workspace-1",
    title: "课程 A",
    status: "open",
    visibility: "workspace",
    enrollmentPolicy: "open",
    capacity: null,
    confirmedCount: 0,
    registrationDeadline: null,
    pricingEnabled: false,
    priceTiers: null,
  };
  const COURSE_B = { ...COURSE_A, id: "course-b", title: "课程 B" };

  it("已报名课程渲染「已报名」徽标，未报名行不渲染", async () => {
    mocks.fetchWorkspaceOfferings.mockResolvedValueOnce([COURSE_A, COURSE_B]);
    mocks.fetchMyActiveEnrollments.mockResolvedValueOnce([
      { id: "enr-1", status: "confirmed", courseId: "course-a", eventId: null },
    ]);

    render(<OfferingsListPage slug="demo" kind="course" />);

    expect(await screen.findByText("课程 A")).toBeInTheDocument();
    const badge = screen.getByTestId("my-enrollment-confirmed");
    expect(badge).toHaveTextContent("已报名");
    // 只有已报名那一行有徽标
    expect(screen.getAllByTestId(/^my-enrollment-/)).toHaveLength(1);
  });

  it("待支付与审批中各自渲染对应文案", async () => {
    mocks.fetchWorkspaceOfferings.mockResolvedValueOnce([COURSE_A, COURSE_B]);
    mocks.fetchMyActiveEnrollments.mockResolvedValueOnce([
      {
        id: "enr-2",
        status: "payment_pending",
        courseId: "course-a",
        eventId: null,
      },
      { id: "enr-3", status: "pending", courseId: "course-b", eventId: null },
    ]);

    render(<OfferingsListPage slug="demo" kind="course" />);

    expect(await screen.findByTestId("my-enrollment-payment_pending")).toHaveTextContent(
      "待支付",
    );
    expect(screen.getByTestId("my-enrollment-pending")).toHaveTextContent("审批中");
  });

  it("活动列表按 eventId 对齐：课程报名不串到活动行", async () => {
    mocks.fetchWorkspaceOfferings.mockResolvedValueOnce([
      { ...COURSE_A, id: "event-a", title: "活动 A" },
    ]);
    mocks.fetchMyActiveEnrollments.mockResolvedValueOnce([
      { id: "enr-c", status: "confirmed", courseId: "event-a", eventId: null },
      { id: "enr-e", status: "pending", courseId: null, eventId: "event-a" },
    ]);

    render(<OfferingsListPage slug="demo" kind="event" />);

    expect(await screen.findByTestId("my-enrollment-pending")).toHaveTextContent(
      "审批中",
    );
    expect(
      screen.queryByTestId("my-enrollment-confirmed"),
    ).not.toBeInTheDocument();
  });

  it("未登录：不发报名查询，也不渲染徽标", async () => {
    authState.current = { authed: false, confirmed: true, userId: null };
    mocks.fetchWorkspaceOfferings.mockResolvedValueOnce([COURSE_A]);

    render(<OfferingsListPage slug="demo" kind="course" />);

    expect(await screen.findByText("课程 A")).toBeInTheDocument();
    expect(mocks.fetchMyActiveEnrollments).not.toHaveBeenCalled();
    expect(screen.queryByTestId(/^my-enrollment-/)).not.toBeInTheDocument();
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
    // 注：rerender 后组件实例复用（wrapper 保留 provider 树），后续渲染可能多于一次，
    // 故 readOnly 分支用持久 mockReturnValue（恒为只读，语义一致）。
    mocks.useWorkspaceBySlug
      .mockReturnValueOnce({
        ws: undefined,
        readOnlyVisitor: false,
        loading: true,
        error: null,
        retry: vi.fn(),
      })
      .mockReturnValue({
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

  it("收费活动：默认选中第一档 + 可换档,tierId 随报名提交", async () => {
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

    // 默认选中第一档：按钮直接带第一档价格,无需手点
    expect(
      await screen.findByRole("button", { name: "报名并支付 ¥99.00" }),
    ).toBeInTheDocument();
    expect(
      within(screen.getByTestId("price-tier-tier-1")).getByRole("radio"),
    ).toBeChecked();

    // 换档（radio）→ 提交携带 tierId；payment_pending 态自动弹收银模态框
    fireEvent.click(screen.getByTestId("price-tier-tier-2"));
    fireEvent.click(screen.getByRole("button", { name: "报名并支付 ¥199.00" }));

    await waitFor(() => expect(submitEnrollment).toHaveBeenCalledTimes(1));
    expect(submitEnrollment).toHaveBeenCalledWith(
      expect.objectContaining({ tierId: "tier-2", eventId: "event-paid" }),
    );

    expect(await screen.findByTestId("checkout-dialog")).toBeInTheDocument();
  });
});

describe("OfferingDetailPage 课程内容治理入口（H6：教研角色可见）", () => {
  const courseRow = () =>
    offeringRow({ id: "course-1", title: "Python 入门", curriculumRequirements: null });

  it("Owner 见治理入口链接；U8 run 状态行已随隐私切换退役", async () => {
    await renderManageDetail("course", courseRow());
    const link = screen.getByTestId("course-governance-link");
    expect(link.getAttribute("href")).toContain("/courses/course-1/curriculum");
    expect(screen.queryByTestId("research-run-status")).not.toBeInTheDocument();
    expect(screen.queryByTestId("research-content-status")).not.toBeInTheDocument();
  });

  it("Tutor（无 manage_events 能力的教研角色）同样见治理入口", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue({
      ws: {
        ...WORKSPACE,
        myRoleNames: ["tutor"],
        myAbilities: ["view_workspace", "access_invite_only"],
      },
      readOnlyVisitor: false,
      loading: false,
      error: null,
      retry: vi.fn(),
    });
    mocks.fetchOffering.mockResolvedValueOnce(courseRow());
    render(<OfferingDetailPage slug="demo" id="course-1" kind="course" />);
    await screen.findByRole("heading", { name: "Python 入门" });
    expect(screen.getByTestId("course-governance-link")).toBeInTheDocument();
  });

  it("无教研角色成员（learner/无标签）不见治理入口", async () => {
    mocks.fetchOffering.mockResolvedValueOnce(courseRow());
    render(<OfferingDetailPage slug="demo" id="course-1" kind="course" />);
    await screen.findByRole("heading", { name: "Python 入门" });
    expect(screen.queryByTestId("course-governance-link")).not.toBeInTheDocument();
  });

  it("event 详情页不渲染治理入口", async () => {
    await renderManageDetail("event", offeringRow({ id: "event-1" }));
    expect(screen.queryByTestId("course-governance-link")).not.toBeInTheDocument();
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

  function renderCourse(id: string, status = "open") {
    mocks.useWorkspaceBySlug.mockReturnValue({
      ws: WORKSPACE,
      readOnlyVisitor: false,
      loading: false,
      error: null,
      retry: vi.fn(),
    });
    mocks.fetchOffering.mockResolvedValueOnce({
      id,
      title: "示例课程",
      status,
      visibility: "workspace",
      enrollmentPolicy: "open",
      registrationDeadline: null,
      capacity: null,
      confirmedCount: 0,
    });
    render(<OfferingDetailPage slug="demo" id={id} kind="course" />);
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

  it("课程 confirmed 既有报名 → 「进入课程」直达 /learning/courses/:id（P0-1）", async () => {
    mocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-course",
      status: "confirmed",
    });

    renderCourse("course-1");

    const link = await screen.findByTestId("enrollment-enter-course");
    expect(link.getAttribute("href")).toContain("/learning/courses/course-1");
    expect(link.textContent).toContain("进入课程");
    const follow = screen.getByRole("link", { name: /在「我的学习」查看/ });
    expect(follow.getAttribute("href")).toContain("/learning");
  });

  it("课程未开课（startsAt 在未来）→ CTA 分叉为开课提示文案（P0-1）", async () => {
    const future = new Date(Date.now() + 7 * 24 * 3600 * 1000).toISOString();
    mocks.useWorkspaceBySlug.mockReturnValue({
      ws: WORKSPACE,
      readOnlyVisitor: false,
      loading: false,
      error: null,
      retry: vi.fn(),
    });
    mocks.fetchOffering.mockResolvedValueOnce({
      id: "course-future",
      title: "未来课程",
      status: "open",
      visibility: "workspace",
      enrollmentPolicy: "open",
      registrationDeadline: null,
      startsAt: future,
      capacity: null,
      confirmedCount: 0,
    });
    mocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-future",
      status: "confirmed",
    });

    render(<OfferingDetailPage slug="demo" id="course-future" kind="course" />);

    const link = await screen.findByTestId("enrollment-enter-course");
    expect(link.textContent).toContain("开课后在此学习");
  });

  it("活动 confirmed 既有报名 → 无「进入课程」；出口落 enrollments tab + 「添加日历」（P0-1/P1a）", async () => {
    mocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-event",
      status: "confirmed",
    });

    renderOpen();

    expect(await screen.findByText("你已报名该活动。")).toBeInTheDocument();
    expect(
      screen.queryByTestId("enrollment-enter-course"),
    ).not.toBeInTheDocument();
    const link = screen.getByRole("link", { name: /在「我的参与」查看/ });
    expect(link.getAttribute("href")).toContain("/participations?tab=enrollments");
    // P1a：详情 mock 无 startsAt → 不渲染添加日历
    expect(screen.queryByTestId("add-to-calendar")).not.toBeInTheDocument();
  });

  it("活动 confirmed 且 startsAt/venue 齐备 → 渲染「添加日历」区（P1a）", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue({
      ws: WORKSPACE,
      readOnlyVisitor: false,
      loading: false,
      error: null,
      retry: vi.fn(),
    });
    mocks.fetchOffering.mockResolvedValueOnce({
      id: "event-cal",
      title: "日历活动",
      status: "open",
      visibility: "workspace",
      enrollmentPolicy: "open",
      registrationDeadline: null,
      startsAt: "2099-10-01T02:00:00.000Z",
      endsAt: "2099-10-01T04:00:00.000Z",
      venue: JSON.stringify({ country: "中国", province: "上海", city: "上海", district: "徐汇" }),
      capacity: null,
      confirmedCount: 0,
    });
    mocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-cal",
      status: "confirmed",
    });

    render(<OfferingDetailPage slug="demo" id="event-cal" kind="event" />);

    const section = await screen.findByTestId("add-to-calendar");
    const google = section.querySelector("a")!;
    expect(google.getAttribute("target")).toBe("_blank");
    const href = google.getAttribute("href")!;
    expect(href).toContain("dates=20991001T020000Z%2F20991001T040000Z");
    expect(new URL(href).searchParams.get("location")).toBe("中国 上海 徐汇");
    expect(
      screen.getByRole("button", { name: "下载 .ics 日历文件" }),
    ).toBeInTheDocument();
  });

  it("课程关闭后 confirmed 仍渲染状态卡与入口（P1-5：open 门不再吞已报名状态）", async () => {
    mocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-closed",
      status: "confirmed",
    });

    renderCourse("course-closed", "closed");

    expect(await screen.findByText("你已报名该课程。")).toBeInTheDocument();
    expect(screen.getByTestId("enrollment-enter-course")).toBeInTheDocument();
  });

  it("课程关闭且未报名 → 「报名已关闭」，不渲染报名按钮（P1-5）", async () => {
    renderCourse("course-closed-none", "closed");

    expect(await screen.findByText("报名已关闭。")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "报名" }),
    ).not.toBeInTheDocument();
  });

  it("英文 locale 已报名态渲染 CTA（回归：offerings en 键缺失 → MISSING_MESSAGE）", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue({
      ws: WORKSPACE,
      readOnlyVisitor: false,
      loading: false,
      error: null,
      retry: vi.fn(),
    });
    mocks.fetchOffering.mockResolvedValueOnce({
      id: "course-en",
      title: "EN Course",
      status: "open",
      visibility: "workspace",
      enrollmentPolicy: "open",
      registrationDeadline: null,
      capacity: null,
      confirmedCount: 0,
    });
    mocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-en",
      status: "confirmed",
    });

    render(<OfferingDetailPage slug="demo" id="course-en" kind="course" />, {
      locale: "en",
    });

    expect(await screen.findByText("Enter course")).toBeInTheDocument();
    expect(
      screen.getByRole("link", { name: "View in My learning" }),
    ).toBeInTheDocument();
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
          startsAt: null,
          endsAt: null,
          ...(kind === "event"
            ? { venue: { country: "", province: "", city: "", district: "" } }
            : {}),
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

describe("OfferingDetailPage capacity 警告（R18，ADR-0009 U7）", () => {
  it.each(["event", "course"] as const)(
    "%s 目标容量 < 当前已占席数 → 警告渲染，保存不拦截",
    async (kind) => {
      await renderManageDetail(
        kind,
        offeringRow({ capacity: 10, confirmedCount: 3 }),
      );

      // 初始值（10 ≥ 3）不警告
      expect(
        screen.queryByTestId("capacity-below-occupied-warning"),
      ).not.toBeInTheDocument();

      fireEvent.change(screen.getByLabelText(/名额上限/), {
        target: { value: "1" },
      });

      const warning = screen.getByTestId("capacity-below-occupied-warning");
      expect(warning).toBeInTheDocument();
      expect(warning).toHaveAttribute("role", "alert");
      expect(warning.textContent).toContain("已占 3 席");

      // 不拦截：照常提交且 capacity 按新值下发
      fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));
      await waitFor(() =>
        expect(mocks.updateOffering).toHaveBeenCalledWith(
          "offering-1",
          kind,
          expect.objectContaining({ capacity: 1 }),
        ),
      );
    },
  );

  it("目标容量 ≥ 已占席数 / 留空（不限）→ 不渲染警告", async () => {
    await renderManageDetail(
      "event",
      offeringRow({ capacity: 10, confirmedCount: 3 }),
    );

    fireEvent.change(screen.getByLabelText(/名额上限/), {
      target: { value: "3" },
    });
    expect(
      screen.queryByTestId("capacity-below-occupied-warning"),
    ).not.toBeInTheDocument();

    fireEvent.change(screen.getByLabelText(/名额上限/), {
      target: { value: "" },
    });
    expect(
      screen.queryByTestId("capacity-below-occupied-warning"),
    ).not.toBeInTheDocument();
  });
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
          startsAt: null,
          endsAt: null,
          ...(kind === "course"
            ? { curriculumRequirements: JSON.stringify({ note: "" }) }
            : { venue: { country: "", province: "", city: "", district: "" } }),
          pricingEnabled: false,
          priceTiers: [],
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

  it("slug 撞唯一索引 → 映射为可操作指引，不透传原文", async () => {
    mocks.updateOffering.mockResolvedValueOnce({
      result: null,
      errors: [{ message: "slug: has already been taken" }],
    });

    await renderManageDetail("event", offeringRow({}));

    fireEvent.change(screen.getByLabelText("标题"), { target: { value: "x" } });
    fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

    expect(
      await screen.findByText("保存失败：链接名（slug）已被占用，请换一个。"),
    ).toBeInTheDocument();
    expect(screen.queryByText(/already been taken/)).not.toBeInTheDocument();
  });

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

/* ---------------- U5/R14：开始/结束时间与结构化 venue 录入 ---------------- */

const OWNER_WS_MOCK = {
  ws: OWNER_WORKSPACE,
  readOnlyVisitor: false,
  loading: false,
  error: null,
  retry: vi.fn(),
};

describe("OfferingNewPage 时间与 venue 录入（U5/R14）", () => {
  it("event：填开始/结束时间 + venue 四键 → createOffering 携带 UTC ISO 时间与四键草稿", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue(OWNER_WS_MOCK);
    mocks.createOffering.mockResolvedValueOnce({
      result: { id: "offering-1" },
      errors: [],
    });

    render(<OfferingNewPage slug="demo" kind="event" />);

    fireEvent.change(await screen.findByLabelText(/标题/), {
      target: { value: "线下工作坊" },
    });
    fireEvent.change(screen.getByLabelText(/^开始时间/), {
      target: { value: "2026-09-01T09:30" },
    });
    fireEvent.change(screen.getByLabelText(/^结束时间/), {
      target: { value: "2026-09-01T12:00" },
    });
    fireEvent.change(screen.getByLabelText("国家"), { target: { value: "中国" } });
    fireEvent.change(screen.getByLabelText("省份"), { target: { value: "浙江省" } });
    fireEvent.change(screen.getByLabelText("城市"), { target: { value: "杭州市" } });
    fireEvent.change(screen.getByLabelText("区县"), { target: { value: "西湖区" } });
    fireEvent.click(screen.getByRole("button", { name: "创建活动" }));

    // datetime-local 原值经 toLocalInput/fromLocalInput 转 UTC ISO（KTD6 时序后端复验）；
    // venue 四键草稿原样下发，JsonString 组装在 lib 层（lib/events.test.ts 覆盖）
    await waitFor(() =>
      expect(mocks.createOffering).toHaveBeenCalledWith("workspace-1", "event", {
        title: "线下工作坊",
        enrollmentPolicy: "open",
        visibility: "public",
        capacity: null,
        registrationDeadline: null,
        startsAt: new Date("2026-09-01T09:30").toISOString(),
        endsAt: new Date("2026-09-01T12:00").toISOString(),
        venue: { country: "中国", province: "浙江省", city: "杭州市", district: "西湖区" },
              }),
    );
    expect(routerMocks.push).toHaveBeenCalledWith("/w/demo/events/offering-1");
  });

  it("event：venue 部分填写（缺键）→ 就地拦截提示，不产生提交", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue(OWNER_WS_MOCK);

    render(<OfferingNewPage slug="demo" kind="event" />);

    fireEvent.change(await screen.findByLabelText(/标题/), {
      target: { value: "线下工作坊" },
    });
    fireEvent.change(screen.getByLabelText("国家"), { target: { value: "中国" } });
    fireEvent.click(screen.getByRole("button", { name: "创建活动" }));

    expect(await screen.findByText(/四项齐全/)).toBeInTheDocument();
    expect(mocks.createOffering).not.toHaveBeenCalled();
    expect(routerMocks.push).not.toHaveBeenCalled();
  });

  it("event：venue 全空 → 四键空草稿照常下发（lib 组装为 null），时间留空 → null", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue(OWNER_WS_MOCK);
    mocks.createOffering.mockResolvedValueOnce({
      result: { id: "offering-1" },
      errors: [],
    });

    render(<OfferingNewPage slug="demo" kind="event" />);

    fireEvent.change(await screen.findByLabelText(/标题/), {
      target: { value: "线上分享" },
    });
    fireEvent.click(screen.getByRole("button", { name: "创建活动" }));

    await waitFor(() =>
      expect(mocks.createOffering).toHaveBeenCalledWith("workspace-1", "event", {
        title: "线上分享",
        enrollmentPolicy: "open",
        visibility: "public",
        capacity: null,
        registrationDeadline: null,
        startsAt: null,
        endsAt: null,
        venue: { country: "", province: "", city: "", district: "" },
      }),
    );
  });

  it("course：只有时间输入、无 venue 输入；提交不携带 venue 键", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue(OWNER_WS_MOCK);
    mocks.createOffering.mockResolvedValueOnce({
      result: { id: "offering-1" },
      errors: [],
    });

    render(<OfferingNewPage slug="demo" kind="course" />);

    expect(await screen.findByLabelText(/^开始时间/)).toBeInTheDocument();
    expect(screen.getByLabelText(/^结束时间/)).toBeInTheDocument();
    expect(screen.queryByLabelText("国家")).not.toBeInTheDocument();
    expect(screen.queryByText(/活动地点/)).not.toBeInTheDocument();

    fireEvent.change(screen.getByLabelText(/标题/), {
      target: { value: "春季训练营" },
    });
    fireEvent.change(screen.getByLabelText(/^开始时间/), {
      target: { value: "2026-09-01T09:30" },
    });
    fireEvent.click(screen.getByRole("button", { name: "创建课程" }));

    await waitFor(() =>
      expect(mocks.createOffering).toHaveBeenCalledWith("workspace-1", "course", {
        title: "春季训练营",
        enrollmentPolicy: "open",
        visibility: "public",
        capacity: null,
        registrationDeadline: null,
        startsAt: new Date("2026-09-01T09:30").toISOString(),
        endsAt: null,
      }),
    );
  });

  it.each([
    ["event", "活动"],
    ["course", "课程"],
  ] as const)(
    "%s 创建：end<=start 后端校验错误（KTD6 message-only）→ 映射文案展示，不透传原文",
    async (kind, label) => {
      mocks.useWorkspaceBySlug.mockReturnValue(OWNER_WS_MOCK);
      mocks.createOffering.mockResolvedValueOnce({
        result: null,
        errors: [
          { message: "ends_at must be after starts_at", code: "invalid_changes" },
        ],
      });

      render(<OfferingNewPage slug="demo" kind={kind} />);

      fireEvent.change(await screen.findByLabelText(/标题/), {
        target: { value: "x" },
      });
      fireEvent.change(screen.getByLabelText(/^开始时间/), {
        target: { value: "2026-09-02T09:00" },
      });
      fireEvent.change(screen.getByLabelText(/^结束时间/), {
        target: { value: "2026-09-01T09:00" },
      });
      fireEvent.click(screen.getByRole("button", { name: `创建${label}` }));

      expect(
        await screen.findByText("结束时间须晚于开始时间。"),
      ).toBeInTheDocument();
      expect(screen.queryByText(/ends_at must be after/)).not.toBeInTheDocument();
      expect(routerMocks.push).not.toHaveBeenCalled();
    },
  );
});

describe("OfferingDetailPage MetaDraft 时间与 venue（U5/R14）", () => {
  it("event：预填 startsAt/venue → 修改后保存携带 UTC ISO 时间与 venue 四键草稿", async () => {
    const startsIso = "2026-09-01T01:30:00.000Z";
    const venueJson = JSON.stringify({
      country: "中国",
      province: "浙江省",
      city: "杭州市",
      district: "西湖区",
    });
    mocks.updateOffering.mockResolvedValueOnce({
      result: {
        id: "offering-1",
        title: "测试活动",
        status: "draft",
        visibility: "public",
        enrollmentPolicy: "open",
        capacity: null,
        registrationDeadline: null,
        startsAt: startsIso,
        endsAt: "2026-09-01T04:00:00.000Z",
        venue: venueJson,
      },
      errors: [],
    });

    await renderManageDetail(
      "event",
      offeringRow({ startsAt: startsIso, endsAt: null, venue: venueJson }),
    );

    // 预填：startsAt 回读同一时刻（toLocalInput 往返）；endsAt null → 空；venue 四键回填
    const startsInput = screen.getByLabelText(/^开始时间/) as HTMLInputElement;
    expect(startsInput.value).not.toBe("");
    expect(new Date(startsInput.value).toISOString()).toBe(startsIso);
    expect(
      (screen.getByLabelText(/^结束时间/) as HTMLInputElement).value,
    ).toBe("");
    expect((screen.getByLabelText("国家") as HTMLInputElement).value).toBe("中国");
    expect((screen.getByLabelText("区县") as HTMLInputElement).value).toBe("西湖区");

    fireEvent.change(screen.getByLabelText(/^结束时间/), {
      target: { value: "2026-09-01T12:00" },
    });
    fireEvent.change(screen.getByLabelText("区县"), { target: { value: "滨江区" } });
    fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

    await waitFor(() =>
      expect(mocks.updateOffering).toHaveBeenCalledWith("offering-1", "event", {
        title: "测试活动",
        enrollmentPolicy: "open",
        capacity: null,
        registrationDeadline: null,
        startsAt: new Date(startsInput.value).toISOString(),
        endsAt: new Date("2026-09-01T12:00").toISOString(),
        venue: { country: "中国", province: "浙江省", city: "杭州市", district: "滨江区" },
        pricingEnabled: false,
        priceTiers: [],
      }),
    );
    expect(await screen.findByText("已保存")).toBeInTheDocument();
  });

  it("event：venue 清空其一（缺键）→ 就地拦截提示，updateOffering 不调用", async () => {
    await renderManageDetail(
      "event",
      offeringRow({
        venue: JSON.stringify({
          country: "中国",
          province: "浙江省",
          city: "杭州市",
          district: "西湖区",
        }),
      }),
    );

    fireEvent.change(screen.getByLabelText("区县"), { target: { value: "" } });
    fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

    expect(await screen.findByText(/四项齐全/)).toBeInTheDocument();
    expect(mocks.updateOffering).not.toHaveBeenCalled();
  });

  it("course：MetaDraft 有时间输入、无 venue 输入；保存不携带 venue 键", async () => {
    mocks.updateOffering.mockResolvedValueOnce({
      result: {
        id: "offering-1",
        title: "测试活动",
        status: "draft",
        visibility: "public",
        enrollmentPolicy: "open",
        capacity: null,
        registrationDeadline: null,
        startsAt: "2026-09-01T01:30:00.000Z",
        endsAt: null,
      },
      errors: [],
    });

    await renderManageDetail("course", offeringRow({}));

    expect(screen.getByLabelText(/^开始时间/)).toBeInTheDocument();
    expect(screen.getByLabelText(/^结束时间/)).toBeInTheDocument();
    expect(screen.queryByLabelText("国家")).not.toBeInTheDocument();
    expect(screen.queryByText(/活动地点/)).not.toBeInTheDocument();

    fireEvent.change(screen.getByLabelText(/^开始时间/), {
      target: { value: "2026-09-01T09:30" },
    });
    fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

    await waitFor(() =>
      expect(mocks.updateOffering).toHaveBeenCalledWith("offering-1", "course", {
        title: "测试活动",
        enrollmentPolicy: "open",
        capacity: null,
        registrationDeadline: null,
        startsAt: new Date("2026-09-01T09:30").toISOString(),
        endsAt: null,
        curriculumRequirements: JSON.stringify({ note: "" }),
        pricingEnabled: false,
        priceTiers: [],
      }),
    );
  });

  it("event：end<=start 后端校验错误（KTD6）→ 映射文案展示，不透传原文", async () => {
    mocks.updateOffering.mockResolvedValueOnce({
      result: null,
      errors: [
        { message: "ends_at must be after starts_at", code: "invalid_changes" },
      ],
    });

    await renderManageDetail("event", offeringRow({}));

    fireEvent.change(screen.getByLabelText(/^开始时间/), {
      target: { value: "2026-09-02T09:00" },
    });
    fireEvent.change(screen.getByLabelText(/^结束时间/), {
      target: { value: "2026-09-01T09:00" },
    });
    fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

    expect(
      await screen.findByText("结束时间须晚于开始时间。"),
    ).toBeInTheDocument();
    expect(screen.queryByText(/ends_at must be after/)).not.toBeInTheDocument();
  });
});

describe("收费设置表单（U6/R1/R2，AE4/KTD9）", () => {
  it("AE4：免费创建——收费区默认收起、提交 payload 不含定价字段", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue(OWNER_WS_MOCK);
    mocks.createOffering.mockResolvedValueOnce({ result: { id: "offering-1" }, errors: [] });

    render(<OfferingNewPage slug="demo" kind="event" />);

    fireEvent.change(await screen.findByLabelText(/标题/), {
      target: { value: "免费分享会" },
    });
    // 收费区收起（<details open=false>，未展开）
    const section = screen.getByTestId("pricing-section") as HTMLDetailsElement;
    expect(section.open).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "创建活动" }));

    const call = mocks.createOffering.mock.calls[0];
    expect(call[0]).toBe("workspace-1");
    expect(call[2]).not.toHaveProperty("pricingEnabled");
    expect(call[2]).not.toHaveProperty("priceTiers");
  });

  it("开启收费零档位 → 就地拦截，不提交", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue(OWNER_WS_MOCK);

    render(<OfferingNewPage slug="demo" kind="event" />);

    fireEvent.change(await screen.findByLabelText(/标题/), {
      target: { value: "收费工作坊" },
    });
    fireEvent.click(screen.getByText("收费设置（可选）"));
    fireEvent.click(screen.getByTestId("pricing-toggle"));
    fireEvent.click(screen.getByRole("button", { name: "创建活动" }));

    expect(await screen.findByText(/至少一个有效档位/)).toBeInTheDocument();
    expect(mocks.createOffering).not.toHaveBeenCalled();
  });

  it("收费创建：payload 含 pricingEnabled + 序列化档位", async () => {
    mocks.useWorkspaceBySlug.mockReturnValue(OWNER_WS_MOCK);
    mocks.createOffering.mockResolvedValueOnce({ result: { id: "offering-1" }, errors: [] });

    render(<OfferingNewPage slug="demo" kind="course" />);

    fireEvent.change(await screen.findByLabelText(/标题/), {
      target: { value: "收费课程" },
    });
    fireEvent.click(screen.getByText("收费设置（可选）"));
    fireEvent.click(screen.getByTestId("pricing-toggle"));
    fireEvent.click(screen.getByTestId("tier-add"));
    const nameInput = document.querySelector('[data-testid^="tier-name-"]') as HTMLInputElement;
    const amountInput = document.querySelector('[data-testid^="tier-amount-"]') as HTMLInputElement;
    fireEvent.change(nameInput, { target: { value: "标准" } });
    fireEvent.change(amountInput, { target: { value: "199" } });
    fireEvent.click(screen.getByRole("button", { name: "创建课程" }));

    await waitFor(() => expect(mocks.createOffering).toHaveBeenCalled());
    const input = mocks.createOffering.mock.calls[0][2] as Record<string, unknown>;
    expect(input.pricingEnabled).toBe(true);
    const tiers = input.priceTiers as string[];
    expect(tiers).toHaveLength(1);
    const tier = JSON.parse(tiers[0]);
    expect(tier.name).toBe("标准");
    expect(tier.amount_cents).toBe(19900);
  });

  it("KTD9：编辑面加载含过期档的活动 → 全量档位可编辑，保存下发全量", async () => {
    const tiers = [
      JSON.stringify({ id: "t1", name: "早鸟", amount_cents: 9900 }),
      JSON.stringify({
        id: "t2",
        name: "往期档",
        amount_cents: 19900,
        available_until: "2020-01-01T00:00:00Z",
      }),
    ];

    await renderManageDetail("event", offeringRow({ pricingEnabled: true, priceTiers: tiers }));

    // 编辑区开关可见（收费开启）且两档全部进入编辑器（含过期档）
    expect(screen.getByTestId("pricing-toggle")).toBeChecked();
    const rows = document.querySelectorAll('[data-testid^="tier-row-"]');
    expect(rows).toHaveLength(2);

    // F7：改标题（定价未变）→ 不下发定价键（脏检查）
    fireEvent.change(screen.getByLabelText(/标题/), { target: { value: "改名" } });
    fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

    await waitFor(() => expect(mocks.updateOffering).toHaveBeenCalled());
    const metaOnly = mocks.updateOffering.mock.calls[0][2] as Record<string, unknown>;
    expect(metaOnly).not.toHaveProperty("pricingEnabled");
    expect(metaOnly).not.toHaveProperty("priceTiers");

    // 档位实际变更（删过期档）→ 下发全量剩余档（KTD9 语义：不静默丢档）
    fireEvent.click(screen.getByTestId("tier-remove-t2"));
    fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

    await waitFor(() => expect(mocks.updateOffering).toHaveBeenCalledTimes(2));
    const input = mocks.updateOffering.mock.calls[1][2] as Record<string, unknown>;
    const sent = (input.priceTiers as string[]).map((x) => JSON.parse(x).id);
    expect(sent).toEqual(["t1"]);
    expect(input.pricingEnabled).toBe(true);
  });
});

describe("资金守卫与披露（U8，R9/R10/R11/R16/R17，AE1/AE2/AE3/AE8 前端半）", () => {
  /** 守卫懒查询 mock（文件级 apolloClient.query；三响应序列 = stats/paid/pending） */
  function stubGuardQueries(opts: {
    collectedCents?: number;
    paidRows?: Array<Record<string, unknown>>;
    paidCount?: number;
    pendingCount?: number;
  }) {
    const stats = {
      data: {
        workspacePaymentStats: JSON.stringify({
          collected_cents: opts.collectedCents ?? 0,
          pending_cents: 0,
          refunded_cents: 0,
          refund_failed_cents: 0,
        }),
      },
    };
    const paid = {
      data: {
        workspaceOrders: {
          results: opts.paidRows ?? [],
          count: opts.paidCount ?? (opts.paidRows ?? []).length,
        },
      },
    };
    const pending = {
      data: { workspaceOrders: { results: [], count: opts.pendingCount ?? 0 } },
    };

    apolloClient.query
      .mockReset()
      .mockResolvedValue(stats)
      .mockResolvedValueOnce(stats)
      .mockResolvedValueOnce(paid)
      .mockResolvedValueOnce(pending);
  }

  it("AE1 前端：关闭收费 → 弹窗显示 N/M，取消则不发 mutation", async () => {
    await renderManageDetail(
      "event",
      offeringRow({
        pricingEnabled: true,
        priceTiers: [JSON.stringify({ id: "t1", name: "标准", amount_cents: 19900 })],
      }),
    );

    await stubGuardQueries({
      collectedCents: 3 * 19900,
      paidRows: [
        { tierId: "t1" },
        { tierId: "t1" },
        { tierId: "t1" },
      ],
      paidCount: 3,
      pendingCount: 2,
    });

    fireEvent.click(screen.getByTestId("pricing-toggle"));
    fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

    // 守卫文案要等 stats → paid → pending 三次顺序查询落定；CI 慢机 1s 默认
    // 上限偶发不够（flaky），与 payments-management.test.tsx 同款放宽到 3s
    expect(
      await screen.findByTestId("pricing-disable-guard", {}, { timeout: 3000 }),
    ).toBeInTheDocument();
    expect(
      await screen.findByText(
        /已付 3 人不退款；待付 2 人将免费确认/,
        {},
        { timeout: 3000 },
      ),
    ).toBeInTheDocument();

    fireEvent.click(screen.getByTestId("pricing-guard-cancel"));
    expect(screen.queryByTestId("pricing-disable-guard")).not.toBeInTheDocument();
    expect(mocks.updateOffering).not.toHaveBeenCalled();
  });

  it("AE8：开启收费且有待审批 → 披露 M；确认后执行保存", async () => {
    mocks.fetchPendingCount.mockResolvedValue(2);

    await renderManageDetail(
      "event",
      offeringRow({
        pricingEnabled: false,
        priceTiers: [JSON.stringify({ id: "t1", name: "标准", amount_cents: 19900 })],
      }),
    );

    fireEvent.click(screen.getByTestId("pricing-toggle"));
    fireEvent.click(screen.getByRole("button", { name: "保存元数据" }));

    expect(await screen.findByTestId("pricing-enable-guard")).toBeInTheDocument();
    expect(screen.getByText(/约 2 名待审批者通过后需选择档位付款/)).toBeInTheDocument();

    fireEvent.click(screen.getByTestId("pricing-guard-confirm"));
    await waitFor(() => expect(mocks.updateOffering).toHaveBeenCalled());
  });

  it("AE3：取消收费活动确认弹窗含退款笔数与总金额", async () => {
    await renderManageDetail(
      "event",
      offeringRow({
        status: "open",
        pricingEnabled: true,
        priceTiers: [JSON.stringify({ id: "t1", name: "标准", amount_cents: 19900 })],
      }),
    );

    await stubGuardQueries({
      collectedCents: 5 * 19900,
      paidRows: Array.from({ length: 5 }, () => ({ tierId: "t1" })),
      paidCount: 5,
    });

    fireEvent.click(screen.getByRole("button", { name: "取消" }));

    const disclosure = await screen.findByTestId(
      "cancel-refund-disclosure",
      {},
      { timeout: 3000 },
    );
    expect(disclosure).toHaveTextContent("5");
    expect(disclosure).toHaveTextContent("995.00");
  });

  it("AE2 前端：删除已售档触发警告（快照语义文案）", async () => {
    stubGuardQueries({
      collectedCents: 19900,
      paidRows: [{ tierId: "t-sold" }],
      paidCount: 1,
    });

    await renderManageDetail(
      "event",
      offeringRow({
        pricingEnabled: true,
        priceTiers: [
          JSON.stringify({ id: "t-sold", name: "已售档", amount_cents: 19900 }),
          JSON.stringify({ id: "t-free", name: "未售档", amount_cents: 9900 }),
        ],
      }),
    );

    await stubGuardQueries({
      collectedCents: 19900,
      paidRows: [{ tierId: "t-sold" }],
      paidCount: 1,
    });

    // 守卫数据就绪后删除已售档 → 警告出现
    await waitFor(() => {
      const removeSold = screen.queryByTestId("tier-remove-t-sold");
      if (removeSold) fireEvent.click(removeSold);
    });

    expect(await screen.findByTestId("sold-tier-warning")).toBeInTheDocument();
  });
});

describe("OfferingDetailPage 配套课程卡（issue #505 D1）", () => {
  const COMPANION = JSON.stringify({
    id: "course-9",
    slug: "agent-bootcamp",
    title: "Agent 训练营",
  });

  it("event 有配套课程 → 渲染卡片链接到工作台课程详情", async () => {
    await renderManageDetail(
      "event",
      offeringRow({ id: "event-1", companionCourse: COMPANION }),
    );

    const card = await screen.findByTestId("companion-course-card");
    const link = within(card).getByRole("link", { name: /Agent 训练营/ });
    expect(link).toHaveAttribute("href", "/w/demo/courses/course-9");
  });

  it("event 无配套课程 → 不渲染", async () => {
    await renderManageDetail(
      "event",
      offeringRow({ id: "event-2", companionCourse: null }),
    );

    expect(
      screen.queryByTestId("companion-course-card"),
    ).not.toBeInTheDocument();
  });

  it("course 详情不渲染（kind 门）", async () => {
    await renderManageDetail(
      "course",
      offeringRow({ id: "course-1", companionCourse: COMPANION }),
    );

    expect(
      screen.queryByTestId("companion-course-card"),
    ).not.toBeInTheDocument();
  });
});
