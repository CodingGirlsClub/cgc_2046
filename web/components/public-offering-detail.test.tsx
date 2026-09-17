import { act, cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import PublicOfferingDetailPage from "./public-offering-detail";
import { MY_PENDING_ORDERS, ORDER_STATUS } from "@/lib/graphql/orders";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";


const mocks = vi.hoisted(() => ({
  fetchPublicOffering: vi.fn(),
  submitEnrollment: vi.fn(),
}));

const eventsMocks = vi.hoisted(() => ({
  fetchMyEnrollment: vi.fn(),
}));

const initiativesMocks = vi.hoisted(() => ({
  fetchPublicInitiatives: vi.fn(),
}));

// 核销码二维码（qrcode MIT；happy-dom 无 canvas 2D 上下文，同订单页测试替桩）
const { QRCodeStub } = vi.hoisted(() => ({ QRCodeStub: { toDataURL: vi.fn() } }));

// Apollo 边界（收银模态框的下单/轮询）：默认不返回值 → 模态框按「守卫查询失败」兜底
// （与改动前的真实网络失败行为一致）；支付成功路径由用例逐条排练
const apollo = vi.hoisted(() => ({ query: vi.fn(), mutate: vi.fn() }));
vi.mock("@/lib/apollo-client", () => ({
  client: { query: apollo.query, mutate: apollo.mutate },
}));

vi.mock("qrcode", () => ({ default: QRCodeStub }));

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
  fetchMyEnrollment: eventsMocks.fetchMyEnrollment,
  // 透传式格式化：非空 → FMT(<原值>) 便于断言；空 → 调用方兜底文案（同真实 formatDeadline 语义）
  formatDeadline: (value: string | null, undecided: string) =>
    value ? `FMT(${value})` : undecided,
}));

// fetchPublicOffering/submitEnrollment 走 mock；parseVenue/formatVenue/parseSponsorshipTiers
// 用真实实现（venue/赞助 JsonString 解析路径一并覆盖）
vi.mock("@/lib/public-offerings", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/public-offerings")>();
  return {
    ...actual,
    fetchPublicOffering: mocks.fetchPublicOffering,
    submitEnrollment: mocks.submitEnrollment,
  };
});

vi.mock("@/lib/graphql/initiatives", () => ({
  fetchPublicInitiatives: initiativesMocks.fetchPublicInitiatives,
}));

// 可变为匿名态（满员/游客分叉用）；beforeEach 复位为登录态
const authState = vi.hoisted(() => ({
  current: { authed: true, confirmed: true, userId: "user-1" as string | null },
}));
vi.mock("@/lib/use-authed", () => ({
  useAuthed: () => authState.current,
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
  useParams: () => ({ slug: "paid-event" }),
  useRouter: () => ({ push: vi.fn(), replace: vi.fn(), refresh: vi.fn() }),
  usePathname: () => "/events/paid-event",
}));

vi.mock("@/components/learning/course-map-section", () => ({
  default: () => null,
}));

vi.mock("@/components/sponsorship-intent-form", () => ({
  default: () => null,
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
  enrollmentBadge: "enrolling",
  availablePriceTiers: [
    JSON.stringify({ id: "tier-1", name: "早鸟", amount_cents: 100 }),
    JSON.stringify({ id: "tier-2", name: "标准", amount_cents: 19900 }),
  ],
};

beforeEach(() => {
  vi.clearAllMocks();
  authState.current = { authed: true, confirmed: true, userId: "user-1" };
  mocks.fetchPublicOffering.mockResolvedValue(PAID_OFFERING);
  eventsMocks.fetchMyEnrollment.mockResolvedValue(null);
  initiativesMocks.fetchPublicInitiatives.mockResolvedValue([]);
  QRCodeStub.toDataURL.mockResolvedValue("data:image/png;base64,qr");
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

    expect(
      await screen.findByRole("button", { name: "提交报名" }),
    ).toBeInTheDocument();
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
    // 静态信息块（R9，匿名可见）+ radio 选档器（登录态选择控件）各渲染一份金额
    expect(screen.getAllByText("¥1.00")).toHaveLength(2);
    expect(screen.getAllByText("¥199.00")).toHaveLength(2);

    // 未选档 → 前端拒绝，不触 mutation
    // 未选档：按钮仍为「提交报名」占位（金额档未定），点击被前端拒
    fireEvent.click(screen.getByRole("button", { name: "提交报名" }));
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "请先选择价格档位",
    );
    expect(mocks.submitEnrollment).not.toHaveBeenCalled();

    // 选档 → 提交携带 tierId
    fireEvent.click(screen.getByTestId("price-tier-tier-2"));
    fireEvent.click(screen.getByRole("button", { name: "报名并支付 ¥199.00" }));

    await waitFor(() =>
      expect(mocks.submitEnrollment).toHaveBeenCalledTimes(1),
    );
    expect(mocks.submitEnrollment).toHaveBeenCalledWith(
      expect.objectContaining({ tierId: "tier-2", eventId: "evt-paid" }),
    );

    // payment_pending 态：待支付提示 + 自动弹收银模态框（就地支付）
    expect(await screen.findByText(/待支付（名额已保留）/)).toBeInTheDocument();
    expect(await screen.findByTestId("checkout-dialog")).toBeInTheDocument();
  });
  // ── #510 年龄门槛：公开详情页（主报名入口）勾选确认门 ──

  it("年龄门槛条目：未勾选先拦截,勾选后提交携带 ageConfirmed（#510）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      id: "evt-age",
      pricingEnabled: false,
      availablePriceTiers: null,
      minAge: 18,
    });
    mocks.submitEnrollment.mockResolvedValueOnce({
      result: { id: "enr-age", status: "confirmed" },
      errors: [],
    });

    render(<PublicOfferingDetailPage kind="event" />);

    const checkbox = await screen.findByTestId("age-confirm-checkbox");
    expect(checkbox).not.toBeChecked();
    expect(
      screen.getByText("我确认已年满 18 周岁，符合本活动的年龄要求。"),
    ).toBeInTheDocument();

    // 未勾选 → 本地拦截，mutation 不出门
    fireEvent.click(screen.getByRole("button", { name: "提交报名" }));
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "请先勾选年龄确认。",
    );
    expect(mocks.submitEnrollment).not.toHaveBeenCalled();

    // 勾选 → 提交携带 ageConfirmed: true
    fireEvent.click(checkbox);
    fireEvent.click(screen.getByRole("button", { name: "提交报名" }));
    await waitFor(() =>
      expect(mocks.submitEnrollment).toHaveBeenCalledTimes(1),
    );
    expect(mocks.submitEnrollment).toHaveBeenCalledWith(
      expect.objectContaining({ eventId: "evt-age", ageConfirmed: true }),
    );
  });

  it("无年龄门槛条目：不出勾选框，提交不携带 ageConfirmed（#510）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      id: "evt-noage",
      pricingEnabled: false,
      availablePriceTiers: null,
      minAge: null,
    });
    mocks.submitEnrollment.mockResolvedValueOnce({
      result: { id: "enr-noage", status: "confirmed" },
      errors: [],
    });

    render(<PublicOfferingDetailPage kind="event" />);

    await screen.findByRole("button", { name: "提交报名" });
    expect(screen.queryByTestId("age-confirm-field")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "提交报名" }));
    await waitFor(() =>
      expect(mocks.submitEnrollment).toHaveBeenCalledTimes(1),
    );
    expect(mocks.submitEnrollment).toHaveBeenCalledWith(
      expect.not.objectContaining({ ageConfirmed: expect.anything() }),
    );
  });

  it("收费项全过期档（availablePriceTiers 空）：无可售档位提示，不渲染档位 radio", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      availablePriceTiers: [],
    });

    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByTestId("no-available-tier")).toHaveTextContent(
      "当前无可售档位，请联系组织者。",
    );
    expect(screen.queryByTestId("price-tier-tier-1")).not.toBeInTheDocument();
  });

  it("后端 :tier_id_required 错误 → 映射为档位引导文案（错误分支不再死胡同）", async () => {
    mocks.submitEnrollment.mockResolvedValueOnce({
      result: null,
      errors: [
        {
          code: "enrollment_tier_id_required",
          message: "a price tier is required for paid enrollment",
        },
      ],
    });

    render(<PublicOfferingDetailPage kind="event" />);

    await screen.findByTestId("price-tier-picker");
    fireEvent.click(screen.getByTestId("price-tier-tier-1"));
    fireEvent.click(screen.getByRole("button", { name: "报名并支付 ¥1.00" }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "该报名为收费项，请先选择价格档位。",
    );
  });
});

describe("成班徽章（R11）", () => {
  it("short_by 渲染「还差 N 人成班」", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      qualificationStatus: "pending",
      qualificationBadge: "short_by",
      shortBy: 5,
      minParticipants: 8,
    });

    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByText("还差 5 人成班")).toBeInTheDocument();
  });

  it("confirmed 渲染「已成班」，cancelled 渲染「已取消」", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      qualificationStatus: "confirmed",
      qualificationBadge: "confirmed",
      shortBy: null,
    });

    const { unmount } = render(<PublicOfferingDetailPage kind="event" />);
    expect(await screen.findByText("已成班")).toBeInTheDocument();
    unmount();

    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      status: "cancelled",
      qualificationBadge: "cancelled",
      shortBy: null,
    });

    render(<PublicOfferingDetailPage kind="event" />);
    expect(await screen.findByText("已取消")).toBeInTheDocument();
  });

  it("open 徽章不渲染（与报名标签语义重复）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      qualificationBadge: "open",
      shortBy: null,
    });

    render(<PublicOfferingDetailPage kind="event" />);

    await screen.findByRole("button", { name: "提交报名" });
    expect(screen.queryByText("开放报名")).not.toBeInTheDocument();
  });
});

describe("归档场报名门（issue #574：status + badge 双门）", () => {
  // 复现路径：initiative 留档页 → 已取消场公开详情（ReadsArchivedInitiativeEvent
  // 放行匿名读）。fixture 刻意保留「截止未过 + 未满员 + badge=enrolling」——
  // 修复前正是这个组合让表单漏出。
  const CANCELLED = {
    ...PAID_OFFERING,
    status: "cancelled" as const,
    qualificationBadge: "cancelled" as const,
    shortBy: null,
  };

  it("已取消登录态：不出报名表单与选档器，hero 不再显示「报名中」", async () => {
    mocks.fetchPublicOffering.mockResolvedValue(CANCELLED);
    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByTestId("enrollment-cancelled")).toHaveTextContent(
      "该活动已取消，仅供查看。",
    );
    expect(screen.queryByTestId("price-tier-picker")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "提交报名" }),
    ).not.toBeInTheDocument();
    // 归档场由成班标签表达状态；报名标签（「报名中」）不再并列渲染
    expect(screen.queryByText("报名中")).not.toBeInTheDocument();
    expect(screen.getByText("已取消")).toBeInTheDocument();
  });

  it("已取消游客态：不出「登录后报名」入口", async () => {
    authState.current = { authed: false, confirmed: false, userId: null };
    mocks.fetchPublicOffering.mockResolvedValue(CANCELLED);
    render(<PublicOfferingDetailPage kind="event" />);

    expect(
      await screen.findByTestId("enrollment-cancelled"),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("link", { name: "登录后报名" }),
    ).not.toBeInTheDocument();
  });

  it("已结束（status=closed 且 endsAt 已过，badge 仍 enrolling）：提示已结束且不出表单", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      status: "closed",
      qualificationBadge: "closed",
      endsAt: "2020-01-01T00:00:00.000Z",
      shortBy: null,
    });
    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByTestId("enrollment-ended")).toHaveTextContent(
      "该活动已结束，仅供查看。",
    );
    expect(
      screen.queryByRole("button", { name: "提交报名" }),
    ).not.toBeInTheDocument();
    expect(screen.queryByText("报名中")).not.toBeInTheDocument();
  });

  it("closed 但 endsAt 未到（LifecycleWorker 在截止时 close）：提示报名截止而非已结束", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      status: "closed",
      qualificationBadge: "closed",
      endsAt: "2099-01-01T00:00:00.000Z",
      shortBy: null,
    });
    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByTestId("enrollment-closed")).toHaveTextContent(
      "报名已截止，不再接受新的报名。",
    );
    expect(screen.queryByTestId("enrollment-ended")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "提交报名" }),
    ).not.toBeInTheDocument();
  });

  it("draft 预览（owner/admin）：落报名截止桶，不出表单", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      status: "draft",
      qualificationBadge: "open",
      shortBy: null,
    });
    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByTestId("enrollment-closed")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "提交报名" }),
    ).not.toBeInTheDocument();
  });
});

describe("赞助入口门（#574 review：与后端 eligible_target 对齐）", () => {
  const SPONSORABLE = {
    ...PAID_OFFERING,
    pricingEnabled: false,
    availablePriceTiers: null,
    sponsorshipEnabled: true,
    sponsorshipTiers: [
      JSON.stringify({ id: "sp-1", name: "独家赞助", benefits: [], exclusive: true }),
    ],
  };

  it("open + 未过赞助截止：渲染赞助入口", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...SPONSORABLE,
      sponsorshipDeadline: "2099-01-01T00:00:00.000Z",
    });
    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByTestId("public-sponsorship")).toBeInTheDocument();
    expect(screen.getByText("赞助本场")).toBeInTheDocument();
  });

  it("已取消（enabled + 有档位）：不渲染赞助入口", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...SPONSORABLE,
      status: "cancelled",
      qualificationBadge: "cancelled",
      shortBy: null,
    });
    render(<PublicOfferingDetailPage kind="event" />);

    await screen.findByTestId("enrollment-cancelled");
    // 断言用旧代码也存在的标题文案（新 testid 在修复前的代码上恒为 null，会假绿）
    expect(screen.queryByText("赞助本场")).not.toBeInTheDocument();
  });

  it("open 但已过 sponsorshipDeadline：不渲染赞助入口", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...SPONSORABLE,
      sponsorshipDeadline: "2020-01-01T00:00:00.000Z",
    });
    render(<PublicOfferingDetailPage kind="event" />);

    await screen.findByRole("button", { name: "提交报名" });
    expect(screen.queryByText("赞助本场")).not.toBeInTheDocument();
  });
});

describe("公开详情页报名状态分叉（支付接续）", () => {
  function renderOpen() {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
    });
    render(<PublicOfferingDetailPage kind="event" />);
  }

  it("登录态已有 payment_pending 报名 → 待支付卡（去支付入口），不渲染报名表单", async () => {
    eventsMocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-pending",
      status: "payment_pending",
    });

    renderOpen();

    expect(
      await screen.findByTestId("public-enrollment-pending-card"),
    ).toBeInTheDocument();
    expect(screen.getByText(/名额已保留/)).toBeInTheDocument();
    // 批①桌面：继续支付入口开收银模态框（不再跳 /orders/new）
    fireEvent.click(screen.getByTestId("public-enrollment-pending-pay"));
    expect(await screen.findByTestId("checkout-dialog")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "提交报名" }),
    ).not.toBeInTheDocument();
  });

  it("报名截止后已有 payment_pending 报名仍优先显示待支付卡", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "closed",
      registrationDeadline: "2026-08-01T10:00:00+08:00",
    });
    eventsMocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-closed-pending",
      status: "payment_pending",
    });

    render(<PublicOfferingDetailPage kind="event" />);

    expect(
      await screen.findByTestId("public-enrollment-pending-card"),
    ).toBeInTheDocument();
    expect(screen.queryByTestId("enrollment-closed")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "提交报名" }),
    ).not.toBeInTheDocument();
  });

  it("登录态已有 confirmed 报名 → 你已报名，不渲染报名表单", async () => {
    eventsMocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-confirmed",
      status: "confirmed",
    });

    renderOpen();

    expect(await screen.findByText("你已报名该活动。")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "提交报名" }),
    ).not.toBeInTheDocument();
  });

  it("课程 confirmed 报名 → 「进入课程」直达 /learning/courses/:id（P0-1）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      id: "course-pub",
      slug: "pub-course",
      title: "公开课程",
      pricingEnabled: false,
      availablePriceTiers: null,
    });
    eventsMocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-course",
      status: "confirmed",
    });

    render(<PublicOfferingDetailPage kind="course" />);

    const link = await screen.findByTestId("public-enrollment-enter-course");
    expect(link.getAttribute("href")).toContain("/learning/courses/course-pub");
    expect(link.textContent).toContain("进入课程");
  });

  it("课程 confirmed 报名 → 次级出口落在 /learning（P0/P2b）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      id: "course-pub2",
      slug: "pub-course-2",
      title: "公开课程",
      pricingEnabled: false,
      availablePriceTiers: null,
    });
    eventsMocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-course2",
      status: "confirmed",
    });

    render(<PublicOfferingDetailPage kind="course" />);

    const link = await screen.findByRole("link", { name: /在「我的学习」查看/ });
    expect(link.getAttribute("href")).toContain("/learning");
  });

  it("课程未开课（startsAt 在未来）→ CTA 分叉为开课提示文案（P0-1）", async () => {
    const future = new Date(Date.now() + 7 * 24 * 3600 * 1000).toISOString();
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      id: "course-future",
      slug: "future-course",
      pricingEnabled: false,
      availablePriceTiers: null,
      startsAt: future,
    });
    eventsMocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-future",
      status: "confirmed",
    });

    render(<PublicOfferingDetailPage kind="course" />);

    const link = await screen.findByTestId("public-enrollment-enter-course");
    expect(link.textContent).toContain("开课后在此学习");
    expect(link.textContent).toContain(`FMT(${future})`);
  });

  it("活动 confirmed 报名 → 无「进入课程」；出口落 enrollments tab，且有「添加日历」（P0-1/P1a）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      startsAt: "2099-10-01T02:00:00.000Z",
      endsAt: "2099-10-01T04:00:00.000Z",
      venue: JSON.stringify({ country: "中国", province: "上海", city: "上海", district: "徐汇" }),
    });
    eventsMocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-evt",
      status: "confirmed",
    });

    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByText("你已报名该活动。")).toBeInTheDocument();
    expect(
      screen.queryByTestId("public-enrollment-enter-course"),
    ).not.toBeInTheDocument();
    // P0：活动出口落到 /participations 的 enrollments tab
    const link = screen.getByRole("link", { name: /在「我的参与」查看/ });
    expect(link.getAttribute("href")).toContain("/participations?tab=enrollments");
    // P1a：添加日历区（Google 链接 + .ics 按钮；venue 进入 location 参数）
    const section = screen.getByTestId("add-to-calendar");
    const google = section.querySelector("a")!;
    expect(google.getAttribute("target")).toBe("_blank");
    expect(google.getAttribute("rel")).toContain("noopener");
    expect(decodeURIComponent(google.getAttribute("href")!)).toContain(
      "calendar.google.com/calendar/render",
    );
    const href = google.getAttribute("href")!;
    expect(href).toContain("dates=20991001T020000Z%2F20991001T040000Z");
    expect(new URL(href).searchParams.get("location")).toBe("中国 上海 徐汇");
    expect(
      screen.getByRole("button", { name: "下载 .ics 日历文件" }),
    ).toBeInTheDocument();
  });

  it("活动无 startsAt → 不渲染「添加日历」（P1a）", async () => {
    eventsMocks.fetchMyEnrollment.mockResolvedValueOnce({
      id: "enr-evt-nodate",
      status: "confirmed",
    });

    renderOpen();

    expect(await screen.findByText("你已报名该活动。")).toBeInTheDocument();
    expect(screen.queryByTestId("add-to-calendar")).not.toBeInTheDocument();
  });
});


describe("公开详情两栏布局（R7/R9/KTD1）", () => {
  it("复用公开导航与主题壳层，按内容主栏 + 报名侧栏呈现完整详情", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      enrollmentBadge: "starting_soon",
      startsAt: "2026-09-01T10:00:00+08:00",
      endsAt: "2026-09-01T12:00:00+08:00",
      registrationDeadline: "2026-08-30T00:00:00+08:00",
      venue: JSON.stringify({
        country: "中国",
        province: "上海",
        city: "上海",
        district: "徐汇",
      }),
      description: "线下分享与结对编程。",
    });
    const { container } = render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByText("即将开始")).toBeInTheDocument();
    expect(screen.getByText("开始")).toBeInTheDocument();
    expect(screen.getByText("FMT(2026-09-01T10:00:00+08:00)")).toBeInTheDocument();
    expect(screen.getByText("结束")).toBeInTheDocument();
    expect(screen.getByText("FMT(2026-09-01T12:00:00+08:00)")).toBeInTheDocument();
    expect(screen.getByText("报名截止")).toBeInTheDocument();
    expect(screen.getByText("FMT(2026-08-30T00:00:00+08:00)")).toBeInTheDocument();
    expect(screen.getByText("报名方式")).toBeInTheDocument();
    expect(screen.getByText("直接报名")).toBeInTheDocument();
    expect(screen.getByText("地点")).toBeInTheDocument();
    expect(screen.getByText("中国 上海 徐汇")).toBeInTheDocument();
    expect(screen.getByText("线下分享与结对编程。")).toBeInTheDocument();

    // 定价档位静态信息块（匿名可见的展示块；radio 选档器仍是登录后的选择控件）
    const info = screen.getByTestId("price-tier-info");
    expect(within(info).getByText("早鸟")).toBeInTheDocument();
    expect(within(info).getByText("标准")).toBeInTheDocument();
    expect(within(info).getByText("¥1.00")).toBeInTheDocument();

    // 统一 SiteHeader：aria-label 取 landing.nav.ariaLabel（主导航）
    const nav = screen.getByRole("navigation", { name: "主导航" });
    expect(within(nav).getByRole("link", { name: "活动" })).toHaveAttribute(
      "aria-current",
      "page",
    );
    expect(screen.getByRole("link", { name: "返回全部公开活动" })).toHaveAttribute(
      "href",
      "/events",
    );
    expect(screen.getByText("工作台")).toBeInTheDocument();

    expect(container.querySelector(".public-catalog")).not.toBeNull();
    expect(container.querySelector("main.public-catalog-main.public-detail-main")).not.toBeNull();
    expect(container.querySelector(".public-detail__facts")).not.toBeNull();
    expect(container.querySelector("aside.public-detail__rail")).not.toBeNull();
    expect(container.querySelector("main.ld-root")).toBeNull();
    // EventStatusTag（开放报名）与 visibility 标签从公开详情移除
    expect(screen.queryByText("开放报名")).toBeNull();
    expect(screen.queryByText("公开可见")).toBeNull();
  });

  it("无开始/结束时间 → 「时间待定」兜底，不出现「即将开始」（AE2）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "enrolling",
      startsAt: null,
      endsAt: null,
      venue: null,
    });
    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findAllByText("时间待定")).toHaveLength(2);
    expect(screen.getByText("地点待定")).toBeInTheDocument();
    expect(screen.queryByText("即将开始")).toBeNull();
  });

  it("course 详情无地点槽（R3）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      id: "cs-1",
      slug: "paid-event",
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "enrolling",
      startsAt: null,
      endsAt: null,
    });
    render(<PublicOfferingDetailPage kind="course" />);

    expect(await screen.findAllByText("时间待定")).toHaveLength(2);
    expect(screen.queryByText("地点")).toBeNull();
  });

  it("满员（AE1）登录态：不呈现报名动作，显示已满提示", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "full",
    });
    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByTestId("enrollment-full")).toHaveTextContent(
      "名额已满",
    );
    expect(screen.getByRole("link", { name: "浏览其他活动" })).toHaveAttribute(
      "href",
      "/events",
    );
    expect(screen.getByText("已满")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "提交报名" }),
    ).not.toBeInTheDocument();
  });

  it("满员（AE1）游客态：同样不呈现「登录后报名」入口", async () => {
    authState.current = { authed: false, confirmed: false, userId: null };
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "full",
    });
    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByTestId("enrollment-full")).toBeInTheDocument();
    expect(
      screen.queryByRole("link", { name: "登录后报名" }),
    ).not.toBeInTheDocument();
  });

  it("报名截止：显示截止提示且不呈现报名动作", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "closed",
      registrationDeadline: "2026-08-01T10:00:00+08:00",
    });
    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByTestId("enrollment-closed")).toHaveTextContent(
      "报名已截止",
    );
    expect(screen.getByRole("link", { name: "浏览其他活动" })).toHaveAttribute(
      "href",
      "/events",
    );
    expect(screen.getAllByText("报名截止")).toHaveLength(2);
    expect(
      screen.queryByRole("button", { name: "提交报名" }),
    ).not.toBeInTheDocument();
  });

  it("课程不可报名时返回课程目录", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      id: "cs-full",
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "full",
    });
    render(<PublicOfferingDetailPage kind="course" />);

    expect(await screen.findByTestId("enrollment-full")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "浏览其他课程" })).toHaveAttribute(
      "href",
      "/courses",
    );
  });

  it("报名失败后重新拉取详情（badge 重派生）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "enrolling",
    });
    mocks.submitEnrollment.mockResolvedValueOnce({
      result: null,
      errors: [{ code: "capacity_full", message: "capacity is full" }],
    });
    render(<PublicOfferingDetailPage kind="event" />);

    fireEvent.click(await screen.findByRole("button", { name: "提交报名" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("提交失败");
    await waitFor(() =>
      expect(mocks.fetchPublicOffering).toHaveBeenCalledTimes(2),
    );
  });

  it("X3 报名失败 refetch 未完成前按钮保持 disabled；resolve 为 full 后按钮消失", async () => {
    // 第一次加载 enrolling；报名失败（满员冲突）后的 refetch 挂起
    mocks.fetchPublicOffering.mockResolvedValueOnce({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "enrolling",
    });
    mocks.submitEnrollment.mockResolvedValueOnce({
      result: null,
      errors: [{ code: "capacity_full", message: "capacity is full" }],
    });

    let releaseRefetch!: (row: typeof PAID_OFFERING) => void;
    const refetchGate = new Promise<typeof PAID_OFFERING>((resolve) => {
      releaseRefetch = resolve;
    });
    mocks.fetchPublicOffering.mockImplementationOnce(() => refetchGate);

    render(<PublicOfferingDetailPage kind="event" />);
    const submit = await screen.findByRole("button", { name: "提交报名" });
    fireEvent.click(submit);

    // 错误文案已出（错误分支已进），但 refetch 仍挂起 → 按钮必须仍 disabled
    expect(await screen.findByRole("alert")).toHaveTextContent("提交失败");
    expect(submit).toBeDisabled();

    // refetch 落定：badge=full → 满员态按钮整体消失（AE1）
    releaseRefetch({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: [],
      enrollmentBadge: "full",
    });
    await waitFor(() =>
      expect(screen.getByTestId("enrollment-full")).toBeInTheDocument(),
    );
    expect(screen.queryByRole("button", { name: "提交报名" })).not.toBeInTheDocument();
  });

  it("B2 报名失败 + refetch reject → reconcileFailed 提示 + resync 出口；提交按钮不回可点态", async () => {
    mocks.fetchPublicOffering.mockResolvedValueOnce({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "enrolling",
    });
    mocks.submitEnrollment.mockResolvedValueOnce({
      result: null,
      errors: [{ code: "capacity_full", message: "full" }],
    });
    mocks.fetchPublicOffering.mockRejectedValueOnce(new Error("network down"));

    render(<PublicOfferingDetailPage kind="event" />);
    fireEvent.click(await screen.findByRole("button", { name: "提交报名" }));

    // 错误 + reconcile 失败双提示出现；提交按钮被 resync 出口替换
    expect(await screen.findByText(/未能同步最新状态/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "提交报名" })).not.toBeInTheDocument();

    // resync 成功 → 回 idle，提交按钮恢复
    mocks.fetchPublicOffering.mockResolvedValueOnce({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "full",
    });
    fireEvent.click(screen.getByTestId("resync-offering"));
    await waitFor(() =>
      expect(screen.getByTestId("enrollment-full")).toBeInTheDocument(),
    );
  });

  it("B2 refetch 永不 settle → 10s 有界超时收敛为 reconcileFailed（不永久锁死）", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      mocks.fetchPublicOffering.mockResolvedValueOnce({
        ...PAID_OFFERING,
        pricingEnabled: false,
        availablePriceTiers: null,
        enrollmentBadge: "enrolling",
      });
      mocks.submitEnrollment.mockResolvedValueOnce({
        result: null,
        errors: [{ code: "capacity_full", message: "full" }],
      });
      // 永不 settle 的 refetch（网络挂死形状）
      mocks.fetchPublicOffering.mockImplementationOnce(
        () => new Promise(() => {}),
      );

      render(<PublicOfferingDetailPage kind="event" />);
      fireEvent.click(await screen.findByRole("button", { name: "提交报名" }));

      // 超时前：错误已出但仍在同步（fake timers 下 findBy 需手动推进）
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
      });
      expect(screen.getByRole("alert")).toHaveTextContent("提交失败");

      // 推进 10s：超时分支收敛为 reconcileFailed
      await act(async () => {
        await vi.advanceTimersByTimeAsync(10_000);
      });
      expect(screen.getByText(/未能同步最新状态/)).toBeInTheDocument();
      expect(screen.getByTestId("resync-offering")).toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  it("B2 失败稳态：resync 按钮显示「重新同步」且可点；resync 在途时 disabled 且二次点击零增调用", async () => {
    mocks.fetchPublicOffering.mockResolvedValueOnce({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "enrolling",
    });
    mocks.submitEnrollment.mockResolvedValueOnce({
      result: null,
      errors: [{ code: "capacity_full", message: "full" }],
    });
    // 首次 reconcile reject → 失败稳态
    mocks.fetchPublicOffering.mockRejectedValueOnce(new Error("down"));

    render(<PublicOfferingDetailPage kind="event" />);
    fireEvent.click(await screen.findByRole("button", { name: "提交报名" }));
    await screen.findByText(/未能同步最新状态/);

    // 失败稳态：按钮名 = 重新同步，enabled（advisor02 第 5 轮 blocker 1 断言形状）
    const resyncBtn = screen.getByTestId("resync-offering") as HTMLButtonElement;
    expect(resyncBtn.textContent).toBe("重新同步");
    expect(resyncBtn.disabled).toBe(false);

    // resync 在途（挂起）→ 按钮 disabled + 文案「同步中…」；
    // 二次点击不产生新请求（fetchPublicOffering 调用数不变）
    let releaseResync!: (row: unknown) => void;
    mocks.fetchPublicOffering.mockImplementationOnce(
      () => new Promise((resolve) => { releaseResync = resolve; }),
    );
    const callsBefore = mocks.fetchPublicOffering.mock.calls.length;
    fireEvent.click(resyncBtn);
    await waitFor(() => {
      const btn = screen.getByTestId("resync-offering") as HTMLButtonElement;
      expect(btn.textContent).toBe("同步中…");
      expect(btn.disabled).toBe(true);
    });
    fireEvent.click(screen.getByTestId("resync-offering"));
    expect(mocks.fetchPublicOffering.mock.calls.length).toBe(callsBefore + 1);

    releaseResync({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      enrollmentBadge: "full",
    });
    await waitFor(() =>
      expect(screen.getByTestId("enrollment-full")).toBeInTheDocument(),
    );
  });

  it("B2 迟到响应不覆盖：R1 超时进失败态 → R2 resync 返回 full → R1 迟到 enrolling 被丢弃", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      mocks.fetchPublicOffering.mockResolvedValueOnce({
        ...PAID_OFFERING,
        pricingEnabled: false,
        availablePriceTiers: null,
        enrollmentBadge: "enrolling",
      });
      mocks.submitEnrollment.mockResolvedValueOnce({
        result: null,
        errors: [{ code: "capacity_full", message: "full" }],
      });
      // R1：永不 settle（将超时）
      let resolveR1!: (row: unknown) => void;
      mocks.fetchPublicOffering.mockImplementationOnce(
        () => new Promise((resolve) => { resolveR1 = resolve; }),
      );

      render(<PublicOfferingDetailPage kind="event" />);
      fireEvent.click(await screen.findByRole("button", { name: "提交报名" }));

      // R1 超时 → 失败稳态
      await act(async () => {
        await vi.advanceTimersByTimeAsync(10_000);
      });
      await screen.findByText(/未能同步最新状态/);

      // R2（resync）立即返回 full → 满员态
      mocks.fetchPublicOffering.mockResolvedValueOnce({
        ...PAID_OFFERING,
        pricingEnabled: false,
        availablePriceTiers: null,
        enrollmentBadge: "full",
      });
      fireEvent.click(screen.getByTestId("resync-offering"));
      await waitFor(() =>
        expect(screen.getByTestId("enrollment-full")).toBeInTheDocument(),
      );

      // R1 迟到 resolve 旧 enrolling —— generation 已过期，回写被丢弃：
      // 满员态保持，提交按钮不重现（若守卫失效，badge 回 enrolling → 表单回来）
      await act(async () => {
        resolveR1({
          ...PAID_OFFERING,
          pricingEnabled: false,
          availablePriceTiers: null,
          enrollmentBadge: "enrolling",
        });
        await vi.advanceTimersByTimeAsync(0);
      });
      expect(screen.getByTestId("enrollment-full")).toBeInTheDocument();
      expect(
        screen.queryByRole("button", { name: "提交报名" }),
      ).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  it("B3 档位失效：报名失败 refetch 删除所选档 → tierId 被清空，旧 id 不再提交", async () => {
    // 初始两档可选，选 tier-2 提交 → 后端 tier_not_available 拒
    mocks.fetchPublicOffering.mockResolvedValueOnce(PAID_OFFERING);
    mocks.submitEnrollment.mockResolvedValueOnce({
      result: null,
      errors: [
        { code: "enrollment_tier_not_available", message: "tier gone" },
      ],
    });
    // refetch 返回：档位下架（只剩 tier-1）+ badge 仍 enrolling
    mocks.fetchPublicOffering.mockResolvedValueOnce({
      ...PAID_OFFERING,
      availablePriceTiers: [
        JSON.stringify({ id: "tier-1", name: "早鸟", amount_cents: 100 }),
      ],
      enrollmentBadge: "enrolling",
    });

    render(<PublicOfferingDetailPage kind="event" />);
    fireEvent.click(await screen.findByTestId("price-tier-tier-2"));
    fireEvent.click(screen.getByRole("button", { name: "报名并支付 ¥199.00" }));

    // reconcile 成功后：tier-2 已下架 → 档位列表只剩 tier-1，
    // tierId 被清空（无选中档）
    expect(await screen.findByRole("alert")).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.queryByTestId("price-tier-tier-2")).not.toBeInTheDocument();
    });
    const tier1Radio = screen
      .getByTestId("price-tier-tier-1")
      .querySelector("input") as HTMLInputElement;
    expect(tier1Radio.checked).toBe(false);
    // 旧 tierId 不在提交 payload 里：再次提交时守卫按 paidTier 判
    // （未选档 → 前端拒，不发带旧 id 的 mutation）
    fireEvent.click(screen.getByRole("button", { name: "提交报名" }));
    expect(await screen.findByText(/请先选择价格档位/)).toBeInTheDocument();
  });

  it("拉取失败：错误消息 + 重试按钮；点击重试触发重新拉取", async () => {
    mocks.fetchPublicOffering.mockRejectedValueOnce(new Error("boom"));
    render(<PublicOfferingDetailPage kind="event" />);

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent("加载失败");
    expect(alert).toHaveTextContent("boom");

    mocks.fetchPublicOffering.mockResolvedValueOnce({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
    });
    fireEvent.click(screen.getByRole("button", { name: "重试" }));

    await waitFor(() =>
      expect(mocks.fetchPublicOffering).toHaveBeenCalledTimes(2),
    );
    expect(
      await screen.findByRole("heading", { name: "收费活动" }),
    ).toBeInTheDocument();
  });

  it("not-accessible：文案中性化为「已结束或不公开访问」", async () => {
    mocks.fetchPublicOffering.mockResolvedValue(null);
    render(<PublicOfferingDetailPage kind="event" />);

    expect(
      await screen.findByRole("heading", { name: "该活动不可访问" }),
    ).toBeInTheDocument();
    expect(screen.getByText("已结束或不公开访问。")).toBeInTheDocument();
    expect(screen.queryByText(/请登录后从工作台内访问/)).toBeNull();
  });
});

describe("F6 键盘焦点环作用域：报名面控件位于 .public-catalog 内", () => {
  it("邀请码 input 与价格档位 radio 渲染于公开主题壳层", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      enrollmentPolicy: "invite_only",
    });
    const { container } = render(<PublicOfferingDetailPage kind="event" />);

    // happy-dom 不加载 globals.css，computed outline 断言不可行 → 结构断言：
    // 控件是 .public-catalog 后代（规则文本守卫在 lib/design-tokens.test.ts G 用例）
    const root = container.querySelector(".public-catalog");
    expect(root).not.toBeNull();

    const invite = await screen.findByLabelText("邀请码（必填）");
    expect(invite.closest(".public-catalog")).not.toBeNull();

    const tier = await screen.findByTestId("price-tier-tier-1");
    const radio = tier.querySelector('input[type="radio"]');
    expect(radio).not.toBeNull();
    expect(radio?.closest(".public-catalog")).not.toBeNull();
  });
});

describe("赞助档位独占位徽标（F6 暗色 token）", () => {
  it("独占位徽标携带 ld-badge-exclusive；渲染输出无硬编码 amber 类", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      sponsorshipEnabled: true,
      sponsorshipTiers: [
        JSON.stringify({
          id: "sp-1",
          name: "独家赞助",
          benefits: [],
          exclusive: true,
        }),
      ],
    });
    const { container } = render(<PublicOfferingDetailPage kind="event" />);

    const badge = await screen.findByText("独占位");
    expect(badge).toHaveClass("ld-badge-exclusive");
    // F6：语义 token 替换硬编码 Tailwind amber，渲染输出零命中
    expect(container.innerHTML).not.toMatch(/bg-amber|text-amber/);
  });
});

describe("配套课程卡（issue #505 D1）", () => {
  const COMPANION = JSON.stringify({
    id: "course-1",
    slug: "agent-bootcamp",
    title: "Agent 训练营",
  });

  it("event 有配套课程 → 渲染课程卡链接到课程公开页", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      companionCourse: COMPANION,
    });

    render(<PublicOfferingDetailPage kind="event" />);

    const card = await screen.findByTestId("public-companion-course");
    expect(card).toBeInTheDocument();
    const link = within(card).getByRole("link", { name: "Agent 训练营" });
    expect(link).toHaveAttribute("href", "/courses/agent-bootcamp");
  });

  it("event 无配套课程（宣讲会）→ 不渲染", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      companionCourse: null,
    });

    render(<PublicOfferingDetailPage kind="event" />);
    await screen.findByRole("button", { name: "提交报名" });

    expect(
      screen.queryByTestId("public-companion-course"),
    ).not.toBeInTheDocument();
  });

  it("course 详情页即使带字段也不渲染（kind 门）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      companionCourse: COMPANION,
    });

    render(<PublicOfferingDetailPage kind="course" />);
    await screen.findByRole("button", { name: "提交报名" });

    expect(
      screen.queryByTestId("public-companion-course"),
    ).not.toBeInTheDocument();
  });
});

describe("倡导活动回链（initiative 挂载）", () => {
  it("挂载场渲染 hero 回链：name + /initiatives/slug", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      initiativeId: "init-1",
    });
    initiativesMocks.fetchPublicInitiatives.mockResolvedValue([
      {
        id: "init-1",
        name: "Hackerstart 1024 全国黑客松",
        slug: "hackerstart1024",
        status: "open",
      },
    ]);

    render(<PublicOfferingDetailPage kind="event" />);

    const link = await screen.findByRole("link", {
      name: /Hackerstart 1024 全国黑客松/,
    });
    expect(link).toHaveAttribute("href", "/initiatives/hackerstart1024");
    expect(screen.getByText(/所属倡导活动/)).toBeInTheDocument();
  });

  it("initiativeId 不在公开列表（draft 不公开）→ 不渲染回链", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
      initiativeId: "init-draft",
    });
    initiativesMocks.fetchPublicInitiatives.mockResolvedValue([
      {
        id: "init-1",
        name: "Hackerstart 1024 全国黑客松",
        slug: "hackerstart1024",
        status: "open",
      },
    ]);

    render(<PublicOfferingDetailPage kind="event" />);
    await screen.findByRole("button", { name: "提交报名" });
    await waitFor(() =>
      expect(initiativesMocks.fetchPublicInitiatives).toHaveBeenCalled(),
    );

    expect(screen.queryByText(/所属倡导活动/)).not.toBeInTheDocument();
  });

  it("未挂载 initiative → 不发起查询、不渲染回链", async () => {
    mocks.fetchPublicOffering.mockResolvedValue({
      ...PAID_OFFERING,
      pricingEnabled: false,
      availablePriceTiers: null,
    });

    render(<PublicOfferingDetailPage kind="event" />);
    await screen.findByRole("button", { name: "提交报名" });

    expect(initiativesMocks.fetchPublicInitiatives).not.toHaveBeenCalled();
    expect(screen.queryByText(/所属倡导活动/)).not.toBeInTheDocument();
  });
});

/** 收银模态框的「已支付」轨道：无活单 → 下单 → 首轮轮询 paid（fake timers 推进） */
function mockPaidCheckoutFlow() {
  const order = {
    id: "o1",
    enrollmentId: "enr-dep",
    provider: "wechat_native",
    outTradeNo: "T1",
    amountCents: 6900,
    status: "pending",
    expireAt: "2099-01-01T00:00:00Z",
    // #580：押金口径判据绑订单快照——创单/轮询负载须带 orderKind
    orderKind: "deposit",
  };
  apollo.query.mockImplementation(({ query }: { query: unknown }) => {
    if (query === MY_PENDING_ORDERS) {
      return Promise.resolve({ data: { myOrders: { results: [] } } });
    }
    if (query === ORDER_STATUS) {
      return Promise.resolve({ data: { orderStatus: { ...order, status: "paid" } } });
    }
    return Promise.resolve({ data: null });
  });
  apollo.mutate.mockResolvedValue({
    data: {
      createOrder: {
        result: order,
        errors: [],
        metadata: {
          credential: JSON.stringify({
            type: "qr_code",
            code_url: "weixin://wxpay/x",
          }),
        },
      },
    },
  });
}

describe("押金场详情与本人看码（R10/R11；KTD5/KTD10）", () => {
  const FREE_EVENT = {
    ...PAID_OFFERING,
    pricingEnabled: false,
    availablePriceTiers: null,
  };
  const DEPOSIT_EVENT = {
    ...FREE_EVENT,
    depositEnabled: true,
    depositAmountCents: 6900,
  };

  it("定价场明示「活动开始前取消全额退」退款规则（#543）；免费场不出", async () => {
    mocks.fetchPublicOffering.mockResolvedValue(PAID_OFFERING);

    render(<PublicOfferingDetailPage kind="event" />);

    const note = await screen.findByTestId("pricing-refund-note");
    expect(note.textContent).toContain("活动开始前取消全额退");

    // 免费场不渲染定价块（连带不出退款规则行）
    mocks.fetchPublicOffering.mockResolvedValue(FREE_EVENT);
    cleanup();
    render(<PublicOfferingDetailPage kind="event" />);
    await screen.findByRole("button", { name: "提交报名" });
    expect(screen.queryByTestId("pricing-refund-note")).not.toBeInTheDocument();
  });

  it("押金场明示「押金 ¥xx（到场退）」与「未到场不退」；免费场不渲染押金块", async () => {
    mocks.fetchPublicOffering.mockResolvedValue(DEPOSIT_EVENT);

    const { unmount } = render(<PublicOfferingDetailPage kind="event" />);

    const info = await screen.findByTestId("deposit-info");
    expect(info).toHaveTextContent("押金 ¥69（到场退）");
    expect(info).toHaveTextContent("未到场不退。");
    unmount();

    mocks.fetchPublicOffering.mockResolvedValue(FREE_EVENT);
    render(<PublicOfferingDetailPage kind="event" />);
    await screen.findByRole("button", { name: "提交报名" });
    expect(screen.queryByTestId("deposit-info")).not.toBeInTheDocument();
  });

  it("押金场报名：不要求选档 → payment_pending → 收银框带押金金额与不退明示", async () => {
    mocks.fetchPublicOffering.mockResolvedValue(DEPOSIT_EVENT);
    mocks.submitEnrollment.mockResolvedValueOnce({
      result: { id: "enr-deposit", status: "payment_pending" },
      errors: [],
    });

    render(<PublicOfferingDetailPage kind="event" />);
    fireEvent.click(await screen.findByRole("button", { name: "提交报名" }));

    await waitFor(() => expect(mocks.submitEnrollment).toHaveBeenCalledTimes(1));
    expect(mocks.submitEnrollment).toHaveBeenCalledWith(
      expect.objectContaining({ eventId: "evt-paid", tierId: null }),
    );

    const dialog = await screen.findByTestId("checkout-dialog");
    expect(dialog).toHaveTextContent("¥69.00");
    const note = within(dialog).getByTestId("checkout-deposit-note");
    expect(note).toHaveTextContent("押金 ¥69（到场退）");
    expect(note).toHaveTextContent("未到场不退。");
  });

  it("押金场报名开框即停同意门（#686 D4 钉）：公开页把 depositEnabled 随载荷传下去，未勾选零创单", async () => {
    mocks.fetchPublicOffering.mockResolvedValue(DEPOSIT_EVENT);
    mocks.submitEnrollment.mockResolvedValueOnce({
      result: { id: "enr-deposit", status: "payment_pending" },
      errors: [],
    });
    eventsMocks.fetchMyEnrollment.mockResolvedValue(null);
    apollo.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

    render(<PublicOfferingDetailPage kind="event" />);
    fireEvent.click(await screen.findByRole("button", { name: "提交报名" }));

    expect(
      await screen.findByTestId("checkout-deposit-consent"),
    ).toBeInTheDocument();
    expect(apollo.mutate).not.toHaveBeenCalled();
  });

  it("confirmed 本人报名：报名卡出示 6 位码 + 承载核销 payload 的二维码，并提示勿截图转发", async () => {
    mocks.fetchPublicOffering.mockResolvedValue(DEPOSIT_EVENT);
    eventsMocks.fetchMyEnrollment.mockResolvedValue({
      id: "enr-1",
      status: "confirmed",
      checkInCode: "654321",
    });

    render(<PublicOfferingDetailPage kind="event" />);

    expect(await screen.findByTestId("check-in-code-value")).toHaveTextContent(
      "654321",
    );
    expect(screen.getByText(/请勿截图转发/)).toBeInTheDocument();
    await waitFor(() =>
      expect(QRCodeStub.toDataURL).toHaveBeenCalledWith(
        "cgc2046:checkin:evt-paid:654321",
        expect.anything(),
      ),
    );
  });

  it("payment_pending 本人报名：不出示核销码（仅待支付卡）", async () => {
    mocks.fetchPublicOffering.mockResolvedValue(DEPOSIT_EVENT);
    eventsMocks.fetchMyEnrollment.mockResolvedValue({
      id: "enr-2",
      status: "payment_pending",
      checkInCode: null,
    });

    render(<PublicOfferingDetailPage kind="event" />);

    await screen.findByTestId("public-enrollment-pending-card");
    expect(screen.queryByTestId("check-in-code-value")).not.toBeInTheDocument();
    expect(QRCodeStub.toDataURL).not.toHaveBeenCalled();
  });

  it("押金支付成功：重拉到 confirmed 后退出待支付中间态，rail 就地出示核销码", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      mocks.fetchPublicOffering.mockResolvedValue(DEPOSIT_EVENT);
      mocks.submitEnrollment.mockResolvedValueOnce({
        result: { id: "enr-dep", status: "payment_pending" },
        errors: [],
      });
      // 进页探测无报名 → 支付后重拉为 confirmed（带核销码）
      eventsMocks.fetchMyEnrollment
        .mockResolvedValueOnce(null)
        .mockResolvedValue({
          id: "enr-dep",
          status: "confirmed",
          checkInCode: "848484",
        });
      mockPaidCheckoutFlow();

      render(<PublicOfferingDetailPage kind="event" />);
      fireEvent.click(await screen.findByRole("button", { name: "提交报名" }));
      // U1：押金收银框先停「以到场为退还条件」确认态——勾选确认后才出码
      fireEvent.click(
        await screen.findByTestId("checkout-deposit-consent-checkbox"),
      );
      fireEvent.click(screen.getByTestId("checkout-deposit-consent-button"));
      await screen.findByTestId("checkout-qr");

      // 首轮轮询（2s）拿到 paid → onPaid 重拉报名 → rail 落到已报名卡
      await act(async () => {
        await vi.advanceTimersByTimeAsync(2_100);
      });

      expect(await screen.findByTestId("check-in-code-value")).toHaveTextContent(
        "848484",
      );
      expect(
        screen.queryByTestId("public-enrollment-pending-card"),
      ).not.toBeInTheDocument();
      expect(screen.queryByText(/待支付（名额已保留）/)).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  it("支付成功但报名重拉失败：保持待支付中间态（继续支付入口仍在），不掉回报名表单", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      mocks.fetchPublicOffering.mockResolvedValue(DEPOSIT_EVENT);
      mocks.submitEnrollment.mockResolvedValueOnce({
        result: { id: "enr-dep", status: "payment_pending" },
        errors: [],
      });
      eventsMocks.fetchMyEnrollment
        .mockResolvedValueOnce(null)
        .mockRejectedValue(new Error("boom"));
      mockPaidCheckoutFlow();

      render(<PublicOfferingDetailPage kind="event" />);
      fireEvent.click(await screen.findByRole("button", { name: "提交报名" }));
      // U1：押金收银框先停「以到场为退还条件」确认态——勾选确认后才出码
      fireEvent.click(
        await screen.findByTestId("checkout-deposit-consent-checkbox"),
      );
      fireEvent.click(screen.getByTestId("checkout-deposit-consent-button"));
      await screen.findByTestId("checkout-qr");
      await act(async () => {
        await vi.advanceTimersByTimeAsync(2_100);
      });

      expect(await screen.findByTestId("checkout-paid")).toBeInTheDocument();
      expect(screen.getByText(/待支付（名额已保留）/)).toBeInTheDocument();
      expect(
        screen.queryByRole("button", { name: "提交报名" }),
      ).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });
});
