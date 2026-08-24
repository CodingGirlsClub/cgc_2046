import { act, cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import PublicOfferingDetailPage from "./public-offering-detail";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";


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

    const nav = screen.getByRole("navigation", { name: "公开内容导航" });
    expect(within(nav).getByRole("link", { name: "活动" })).toHaveAttribute(
      "aria-current",
      "page",
    );
    expect(screen.getByRole("link", { name: "返回全部活动" })).toHaveAttribute(
      "href",
      "/events",
    );
    expect(screen.queryByText("工作台")).toBeNull();

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
