import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  act,
  cleanup,
  fireEvent,
  screen,
  waitFor,
} from "@testing-library/react";
import { render } from "@/test-utils";
import PaymentCheckoutDialog from "./payment-checkout-dialog";

const { client } = vi.hoisted(() => ({
  client: { query: vi.fn(), mutate: vi.fn() },
}));
const { QRCodeStub } = vi.hoisted(() => ({
  QRCodeStub: { toDataURL: vi.fn() },
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));

// jsdom 环境不提供 localStorage/sessionStorage（Node 警告），用 in-memory 实现
function memoryStorage(): Storage {
  const store = new Map<string, string>();
  return {
    get length() {
      return store.size;
    },
    clear: () => store.clear(),
    getItem: (k) => store.get(k) ?? null,
    key: (i) => Array.from(store.keys())[i] ?? null,
    removeItem: (k) => store.delete(k),
    setItem: (k, v) => store.set(k, String(v)),
  };
}
Object.defineProperty(window, "localStorage", {
  value: memoryStorage(),
  configurable: true,
});
Object.defineProperty(window, "sessionStorage", {
  value: memoryStorage(),
  configurable: true,
});
vi.mock("@/lib/apollo-client", () => ({ client }));
vi.mock("qrcode", () => ({ default: QRCodeStub }));
vi.mock("@/lib/use-authed", () => ({ useAuthed }));

const expireAt = "2026-08-16T12:00:00Z";

function pendingOrder(overrides: Record<string, unknown> = {}) {
  return {
    id: "o1",
    enrollmentId: "enr-1",
    provider: "wechat_native",
    outTradeNo: "T1",
    amountCents: 19900,
    status: "pending",
    expireAt,
    ...overrides,
  };
}

function createOrderPayload(overrides: Record<string, unknown> = {}) {
  return {
    createOrder: {
      result: pendingOrder(),
      errors: [],
      metadata: {
        credential: JSON.stringify({
          type: "qr_code",
          code_url: "weixin://wxpay/x",
        }),
      },
      ...overrides,
    },
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  client.mutate.mockResolvedValue({ data: createOrderPayload() });
  QRCodeStub.toDataURL.mockResolvedValue("data:image/png;base64,qr");
  useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
  vi.spyOn(Date, "now").mockReturnValue(Date.parse("2026-08-16T11:00:00Z"));
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
  localStorage.clear();
  sessionStorage.clear();
  cleanup();
});

describe("payment-checkout-dialog 开框初始化", () => {
  it("无活单 → createOrder（默认渠道 wechat_native）→ 二维码渲染 + 记住渠道", async () => {
    client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );

    expect(await screen.findByTestId("checkout-qr")).toHaveAttribute(
      "src",
      "data:image/png;base64,qr",
    );
    expect(QRCodeStub.toDataURL).toHaveBeenCalledWith(
      "weixin://wxpay/x",
      expect.anything(),
    );
    expect(client.mutate).toHaveBeenCalledWith(
      expect.objectContaining({
        variables: {
          input: { enrollmentId: "enr-1", provider: "wechat_native" },
        },
      }),
    );
    expect(screen.getByText("使用微信扫码完成支付")).toBeInTheDocument();
    // 记住渠道（localStorage）
    expect(localStorage.getItem("cgc:last-payment-provider")).toBe(
      "wechat_native",
    );
    // 凭据落 sessionStorage（/orders/[id] 兜底可续）
    expect(sessionStorage.getItem("order-credential:o1")).toBeTruthy();
  });

  it("首开默认渠道：localStorage 有记忆（alipay_qr）则用之", async () => {
    localStorage.setItem("cgc:last-payment-provider", "alipay_qr");
    client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );

    await screen.findByTestId("checkout-qr");
    expect(client.mutate).toHaveBeenCalledWith(
      expect.objectContaining({
        variables: { input: { enrollmentId: "enr-1", provider: "alipay_qr" } },
      }),
    );
  });

  it("localStorage 记忆未签约渠道（脏值）→ 忽略回退 wechat_native", async () => {
    localStorage.setItem("cgc:last-payment-provider", "alipay_page");
    client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );

    await screen.findByTestId("checkout-qr");
    expect(client.mutate).toHaveBeenCalledWith(
      expect.objectContaining({
        variables: {
          input: { enrollmentId: "enr-1", provider: "wechat_native" },
        },
      }),
    );
  });

  it("已有活单 → 复用（不 createOrder）+ 凭据在 sessionStorage → 直接出码", async () => {
    client.query.mockResolvedValue({
      data: { myOrders: { results: [pendingOrder()] } },
    });
    sessionStorage.setItem(
      "order-credential:o1",
      JSON.stringify({ type: "qr_code", code_url: "weixin://wxpay/reuse" }),
    );

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );

    expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
    expect(QRCodeStub.toDataURL).toHaveBeenCalledWith(
      "weixin://wxpay/reuse",
      expect.anything(),
    );
    expect(client.mutate).not.toHaveBeenCalled();
    // 复用路径不焚毁凭据（/orders/[id] 兜底仍可续）
    expect(sessionStorage.getItem("order-credential:o1")).toBeTruthy();
  });

  it("复用活单但凭据丢失（sessionStorage 焚毁）→ 换渠道恢复引导 + 其他渠道按钮 primary", async () => {
    client.query.mockResolvedValue({
      data: { myOrders: { results: [pendingOrder()] } },
    });

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );

    const unsupported = await screen.findByTestId(
      "checkout-credential-unsupported",
    );
    expect(unsupported).toHaveTextContent(/支付凭据已失效/);
    const other = screen.getByTestId("checkout-provider-alipay_qr");
    expect(other).toHaveClass("join-button--primary");
    expect(
      screen.getByTestId("checkout-provider-wechat_native"),
    ).toHaveAttribute("aria-pressed", "true");
  });
});

describe("payment-checkout-dialog 换渠道", () => {
  it("切渠道 → replaceProvider 新凭据即换 + 轮询窗重置 + 更新记忆", async () => {
    client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });
    client.mutate
      .mockResolvedValueOnce({ data: createOrderPayload() })
      .mockResolvedValueOnce({
        data: {
          replaceProvider: {
            result: pendingOrder({ id: "o2", provider: "alipay_qr" }),
            errors: [],
            metadata: {
              credential: JSON.stringify({
                type: "qr_code",
                code_url: "https://qr.alipay.com/y",
              }),
            },
          },
        },
      });

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );

    await screen.findByTestId("checkout-qr");

    fireEvent.click(screen.getByTestId("checkout-provider-alipay_qr"));

    await waitFor(() =>
      expect(QRCodeStub.toDataURL).toHaveBeenCalledWith(
        "https://qr.alipay.com/y",
        expect.anything(),
      ),
    );
    expect(client.mutate).toHaveBeenLastCalledWith(
      expect.objectContaining({
        mutation: expect.anything(),
        variables: { input: { orderId: "o1", provider: "alipay_qr" } },
      }),
    );
    expect(localStorage.getItem("cgc:last-payment-provider")).toBe("alipay_qr");
    expect(screen.getByText("使用支付宝扫一扫完成支付")).toBeInTheDocument();
  });

  it("pending 态渠道按钮禁点自身（防重）", async () => {
    client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );

    await screen.findByTestId("checkout-qr");
    const current = screen.getByTestId("checkout-provider-wechat_native");
    expect(current).toBeDisabled();
  });

  it("replaceProvider 失败 → 翻译层文案，不换码", async () => {
    client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });
    client.mutate
      .mockResolvedValueOnce({ data: createOrderPayload() })
      .mockResolvedValueOnce({
        data: {
          replaceProvider: {
            result: null,
            errors: [{ message: "provider_not_configured" }],
            metadata: null,
          },
        },
      });

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );

    await screen.findByTestId("checkout-qr");
    fireEvent.click(screen.getByTestId("checkout-provider-alipay_qr"));

    expect(await screen.findByTestId("checkout-error")).toHaveTextContent(
      "该支付渠道暂未开通，请选择其他方式。",
    );
  });
});

describe("payment-checkout-dialog 支付成功与关闭", () => {
  it("轮询到 paid → onPaid 触发 + ✓ 报名已确认 + 1.5s 自动关闭（fake timers）", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    client.query
      .mockResolvedValueOnce({ data: { myOrders: { results: [] } } })
      .mockResolvedValue({
        data: { orderStatus: pendingOrder({ status: "paid" }) },
      });
    const onPaid = vi.fn();
    const onClose = vi.fn();

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={onClose}
        onPaid={onPaid}
      />,
    );

    await screen.findByTestId("checkout-polling");

    // 第一轮轮询（2s）拉到 paid
    await vi.advanceTimersByTimeAsync(2100);

    const paid = await screen.findByTestId("checkout-paid");
    expect(paid).toHaveTextContent("支付完成，报名已确认");
    expect(onPaid).toHaveBeenCalledTimes(1);

    // 1.5s 后自动关闭
    await vi.advanceTimersByTimeAsync(1600);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("Esc / 关闭按钮 / 点击遮罩 → onClose（订单保留不撤）", async () => {
    client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });
    const onClose = vi.fn();

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={onClose}
        onPaid={vi.fn()}
      />,
    );

    await screen.findByTestId("checkout-qr");

    fireEvent.click(screen.getByTestId("checkout-close"));
    expect(onClose).toHaveBeenCalledTimes(1);

    fireEvent.keyDown(screen.getByTestId("checkout-dialog"), { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(2);

    fireEvent.click(screen.getByTestId("checkout-overlay"));
    expect(onClose).toHaveBeenCalledTimes(3);
  });

  it("跳转凭据（redirect）：渲染前往支付宝按钮", async () => {
    client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });
    client.mutate.mockResolvedValue({
      data: createOrderPayload({
        metadata: {
          credential: JSON.stringify({
            type: "redirect",
            url: "https://pay.alipay.com/x",
          }),
        },
      }),
    });

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );

    const link = await screen.findByTestId("checkout-redirect");
    expect(link).toHaveAttribute("href", "https://pay.alipay.com/x");
    expect(link).toHaveAttribute("target", "_blank");
  });

  it("createOrder 失败（not_payment_pending）→ 翻译层错误 + error 态可重试", async () => {
    client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });
    client.mutate.mockResolvedValue({
      data: {
        createOrder: {
          result: null,
          errors: [{ message: "enrollment is not awaiting payment" }],
          metadata: null,
        },
      },
    });

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );

    expect(await screen.findByTestId("checkout-error")).toHaveTextContent(
      "报名状态已变化（已支付或已取消），请重新报名或查看我的报名。",
    );
  });

  it("乱序守卫：换渠道后在飞的旧单响应迟到，不覆盖新单（F1）", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    // 第一轮轮询（旧单 o1）挂起受控；换渠道后新单 o2 正常轮询
    const stale = Promise.withResolvers<unknown>();
    client.query
      .mockResolvedValueOnce({ data: { myOrders: { results: [] } } })
      .mockImplementationOnce(() => stale.promise)
      .mockResolvedValue({
        data: {
          orderStatus: pendingOrder({
            id: "o2",
            provider: "alipay_qr",
            status: "pending",
          }),
        },
      });
    client.mutate
      .mockResolvedValueOnce({ data: createOrderPayload() })
      .mockResolvedValueOnce({
        data: {
          replaceProvider: {
            result: pendingOrder({ id: "o2", provider: "alipay_qr" }),
            errors: [],
            metadata: {
              credential: JSON.stringify({
                type: "qr_code",
                code_url: "https://qr.alipay.com/y",
              }),
            },
          },
        },
      });

    render(
      <PaymentCheckoutDialog
        enrollmentId="enr-1"
        onClose={vi.fn()}
        onPaid={vi.fn()}
      />,
    );
    await screen.findByTestId("checkout-qr");

    // 触发第一轮轮询（o1 查询在飞、挂起）
    await vi.advanceTimersByTimeAsync(2100);
    expect(client.query).toHaveBeenCalledTimes(2);

    // 换渠道 → 新单 o2 就位
    fireEvent.click(screen.getByTestId("checkout-provider-alipay_qr"));
    await waitFor(() =>
      expect(QRCodeStub.toDataURL).toHaveBeenCalledWith(
        "https://qr.alipay.com/y",
        expect.anything(),
      ),
    );

    // 旧单响应迟到（cancelled + 已过期）：守卫丢弃，不得把 o2 覆盖成过期态
    await act(async () => {
      stale.resolve({
        data: {
          orderStatus: pendingOrder({
            id: "o1",
            status: "cancelled",
            expireAt: "2026-08-16T10:00:00Z",
          }),
        },
      });
    });

    expect(screen.getByAltText("支付宝支付二维码")).toBeInTheDocument();
    expect(
      screen.queryByTestId("checkout-expired-note"),
    ).not.toBeInTheDocument();
    expect(screen.getByTestId("checkout-polling")).toBeInTheDocument();

    // 新单轮询照常推进（下一 tick 查 o2）
    await vi.advanceTimersByTimeAsync(2100);
    await waitFor(() =>
      expect(client.query).toHaveBeenLastCalledWith(
        expect.objectContaining({ variables: { id: "o2" } }),
      ),
    );
  });
});
