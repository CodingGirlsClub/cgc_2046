import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import PublicOfferingDetailPage from "./public-offering-detail";

const mocks = vi.hoisted(() => ({
  fetchPublicOffering: vi.fn(),
  submitEnrollment: vi.fn(),
}));

const eventsMocks = vi.hoisted(() => ({
  fetchMyEnrollment: vi.fn(),
}));

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
});


describe("U4 详情密度与全暗（R7/R9/KTD1）", () => {
  it("完整呈现描述/三时间/venue/报名政策/定价档位静态块；.ld-root 在场（AE4）", async () => {
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
    expect(
      screen.getByText("开始时间：FMT(2026-09-01T10:00:00+08:00)"),
    ).toBeInTheDocument();
    expect(
      screen.getByText("结束时间：FMT(2026-09-01T12:00:00+08:00)"),
    ).toBeInTheDocument();
    expect(
      screen.getByText("报名截止：FMT(2026-08-30T00:00:00+08:00)"),
    ).toBeInTheDocument();
    expect(screen.getByText("报名策略：直接报名")).toBeInTheDocument();
    expect(screen.getByText("地点：中国 上海 上海 徐汇")).toBeInTheDocument();
    expect(screen.getByText("线下分享与结对编程。")).toBeInTheDocument();

    // 定价档位静态信息块（匿名可见的展示块；radio 选档器仍是登录后的选择控件）
    const info = screen.getByTestId("price-tier-info");
    expect(within(info).getByText("早鸟")).toBeInTheDocument();
    expect(within(info).getByText("标准")).toBeInTheDocument();
    expect(within(info).getByText("¥1.00")).toBeInTheDocument();

    // AE4 结构断言：固定深色门面根在场
    expect(container.querySelector("main.ld-root")).not.toBeNull();
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

    expect(await screen.findByText("开始时间：时间待定")).toBeInTheDocument();
    expect(screen.getByText("结束时间：时间待定")).toBeInTheDocument();
    expect(screen.getByText("地点：地点待定")).toBeInTheDocument();
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

    expect(await screen.findByText("开始时间：时间待定")).toBeInTheDocument();
    expect(screen.queryByText(/地点：/)).toBeNull();
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
