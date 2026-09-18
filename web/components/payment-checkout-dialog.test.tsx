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
import { MY_ENROLLMENT } from "@/lib/graphql/events";
import { MY_PENDING_ORDERS, ORDER_STATUS } from "@/lib/graphql/orders";

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
    // #580：押金口径判据已绑订单快照——默认定价单；押金场景显式 override
    orderKind: "enrollment",
    ...overrides,
  };
}

const emptyEnrollments = { myEnrollments: { results: [] } };

/**
 * #748：弹框自取押金事实（MY_ENROLLMENT）——mock 按 document 分派守卫查询。
 * 非轮询测试误触 ORDER_STATUS 会显式炸掉（流程不对就该红）。
 */
function mockQueries(
  myOrders: unknown,
  myEnrollments: unknown = emptyEnrollments,
) {
  client.query.mockImplementation(async ({ query }: { query: unknown }) => {
    if (query === MY_PENDING_ORDERS) return { data: { myOrders } };
    if (query === MY_ENROLLMENT) return { data: { myEnrollments } };
    throw new Error(`unexpected query: ${String(query)}`);
  });
}

/** 轮询场景分派：初始两查 + 后续 ORDER_STATUS 全走 status */
function mockPollingQueries(orderStatus: unknown) {
  client.query.mockImplementation(async ({ query }: { query: unknown }) => {
    if (query === MY_PENDING_ORDERS) {
      return { data: { myOrders: { results: [] } } };
    }
    if (query === MY_ENROLLMENT) return { data: emptyEnrollments };
    if (query === ORDER_STATUS) return { data: { orderStatus } };
    throw new Error(`unexpected query: ${String(query)}`);
  });
}

/** 押金场报名快照（#748：MY_ENROLLMENT 随返） */
function depositEnrollment(overrides: Record<string, unknown> = {}) {
  return {
    id: "enr-1",
    status: "payment_pending",
    paymentMode: "deposit",
    depositAmountCents: 6900,
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
    mockQueries({ results: [] });

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
    mockQueries({ results: [] });

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
    mockQueries({ results: [] });

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
    mockQueries({ results: [pendingOrder()] });
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
    mockQueries({ results: [pendingOrder()] });

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
    mockQueries({ results: [] });
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
    mockQueries({ results: [] });

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
    mockQueries({ results: [] });
    client.mutate
      .mockResolvedValueOnce({ data: createOrderPayload() })
      .mockResolvedValueOnce({
        data: {
          replaceProvider: {
            result: null,
            errors: [{ code: "order_provider_not_configured" }],
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
    mockPollingQueries(pendingOrder({ status: "paid" }));
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
    // React 18 passive effect 异步调度：paid 态 DOM 渲染与 onPaid effect 执行
    // 之间可被事件循环拆开（CI 慢机器上曾撞进窗口），waitFor 消除时序敏感
    await waitFor(() => expect(onPaid).toHaveBeenCalledTimes(1));

    // 1.5s 后自动关闭
    await vi.advanceTimersByTimeAsync(1600);
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
  });

  it("Esc / 关闭按钮 / 点击遮罩 → onClose（订单保留不撤）", async () => {
    mockQueries({ results: [] });
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
    mockQueries({ results: [] });
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
    mockQueries({ results: [] });
    client.mutate.mockResolvedValue({
      data: {
        createOrder: {
          result: null,
          errors: [
            { code: "order_not_payment_pending", message: "not pending" },
          ],
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
    const dispatch = async ({ query }: { query: unknown }) => {
      if (query === MY_PENDING_ORDERS) {
        return { data: { myOrders: { results: [] } } };
      }
      if (query === MY_ENROLLMENT) return { data: emptyEnrollments };
      if (query === ORDER_STATUS) {
        return {
          data: {
            orderStatus: pendingOrder({
              id: "o2",
              provider: "alipay_qr",
              status: "pending",
            }),
          },
        };
      }
      throw new Error(`unexpected query: ${String(query)}`);
    };
    client.query
      .mockImplementationOnce(dispatch) // 初始 MY_PENDING_ORDERS
      .mockImplementationOnce(dispatch) // 初始 MY_ENROLLMENT
      .mockImplementationOnce(() => stale.promise) // 旧单 o1 第一轮轮询挂起
      .mockImplementation(dispatch); // 新单 o2 轮询
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
    expect(client.query).toHaveBeenCalledTimes(3); // 初始两查（#748 并行）+ o1 首轮轮询

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

describe("payment-checkout-dialog 押金支付前确认（U1：以到场为退还条件）", () => {
	it("押金场（无活单）：开框查活单后停确认态——未勾选时确认按钮禁用、零创单、无二维码", async () => {
		mockQueries({ results: [] }, { results: [depositEnrollment()] });

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		// 确认块出现，押金口径可见
		expect(
			await screen.findByTestId("checkout-deposit-consent"),
		).toBeInTheDocument();
		expect(screen.getByTestId("checkout-deposit-note")).toBeInTheDocument();
		expect(
			screen.getByText("押金以到场为退还条件：到场核销后原路退回，未到场不予退还。"),
		).toBeInTheDocument();

		// 未确认：不下单、无凭据（查活单是只读守卫，#580 口径判据的数据源）
		expect(client.mutate).not.toHaveBeenCalled();
		expect(screen.queryByTestId("checkout-qr")).not.toBeInTheDocument();
		expect(screen.queryByTestId("checkout-loading")).not.toBeInTheDocument();

		// 未勾选：确认按钮禁用
		expect(screen.getByTestId("checkout-deposit-consent-button")).toBeDisabled();
	});

	// #675：押金脏金额（0/缺失/非整数分）→ 说明行不表态「押金（金额待定）」，
	// 框头金额整体不显示——绝不出现「押金 ¥0（到场退）」/「¥0.00」。
	// #748 起识别走报名快照 paymentMode（弹框自取），金额（含脏值）不参与识别：
	// 押金场 + 脏金额 → 披露门照常出现，不 fail-open 成非押金口径。
	it.each([
		["0", 0],
		["非整数分", 0.4],
	])("押金金额脏（%s）：披露门仍在（不 fail-open），说明行落待定、框头无 ¥0", async (_label, dirty) => {
		mockQueries({ results: [] }, { results: [depositEnrollment({ depositAmountCents: dirty })] });

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		expect(
			await screen.findByTestId("checkout-deposit-consent"),
		).toBeInTheDocument();
		const note = screen.getByTestId("checkout-deposit-note");
		expect(note).toHaveTextContent("押金（金额待定）");
		expect(note).toHaveTextContent("未到场不退。");
		expect(screen.getByTestId("checkout-dialog").textContent).not.toContain("¥0");
		// 未确认前零创单
		expect(client.mutate).not.toHaveBeenCalled();
	});

	it("押金场：勾选并确认后才下单 → 二维码渲染", async () => {
		client.mutate.mockResolvedValue({
			data: createOrderPayload({
				result: pendingOrder({ orderKind: "deposit", amountCents: 6900 }),
			}),
		});

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		expect(
			await screen.findByTestId("checkout-deposit-consent"),
		).toBeInTheDocument();
		expect(client.mutate).not.toHaveBeenCalled();

		// 勾选 → 按钮可用 → 确认进入支付
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-checkbox"));
		});
		expect(
			screen.getByTestId("checkout-deposit-consent-button"),
		).toBeEnabled();
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-button"));
		});

		expect(await screen.findByTestId("checkout-qr")).toHaveAttribute(
			"src",
			"data:image/png;base64,qr",
		);
		// #727：押金单创单必须携带同意标记（后端权威闸）
		expect(client.mutate).toHaveBeenCalledWith(
			expect.objectContaining({
				variables: {
					input: {
						enrollmentId: "enr-1",
						provider: "wechat_native",
						depositConsent: true,
					},
				},
			}),
		);
	});

	it("押金场 + 后端拒单（本框识别缺失的 fail-open 类）→ 自愈回 consent 补勾选（#727/#748 F-06）", async () => {
		// 报名快照非押金/不可得（enrollments 空）→ 直接创单不带 consent → 后端拒
		mockQueries({ results: [] });
		client.mutate.mockResolvedValueOnce({
			data: {
				createOrder: {
					result: null,
					errors: [
						{
							code: "order_deposit_consent_required",
							message:
								"deposit consent is required before creating a deposit order",
						},
					],
					metadata: null,
				},
			},
		});
		// 第二次创单（勾选后重试）落押金单：漂移检测放行、出码
		client.mutate.mockResolvedValue({
			data: createOrderPayload({
				result: pendingOrder({ orderKind: "deposit", amountCents: 6900 }),
			}),
		});

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		// 第一次创单：不带 consent（本框押金识别未成立）
		await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(1));
		expect(client.mutate).toHaveBeenLastCalledWith(
			expect.objectContaining({
				variables: {
					input: { enrollmentId: "enr-1", provider: "wechat_native" },
				},
			}),
		);

		// 自愈：不落死 error 态，就地出披露 + 勾选；F-06：后端拒单文案不吞
		// （快照不可得 → 金额走「金额待定」口径，#675）
		expect(
			await screen.findByTestId("checkout-deposit-consent"),
		).toBeInTheDocument();
		expect(screen.getByTestId("checkout-consent-error")).toHaveTextContent(
			"押金支付需先阅读并同意押金条款",
		);
		expect(screen.getByTestId("checkout-deposit-note")).toHaveTextContent(
			"押金（金额待定）",
		);

		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-checkbox"));
		});
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-button"));
		});

		expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
		await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(2));
		expect(client.mutate).toHaveBeenLastCalledWith(
			expect.objectContaining({
				variables: {
					input: {
						enrollmentId: "enr-1",
						provider: "wechat_native",
						depositConsent: true,
					},
				},
			}),
		);
	});

	it("押金场：确认后走复用活单路径（不重复下单）", async () => {
		// #580：复用活单的门由订单快照口径判定——押金单（orderKind=deposit）
		mockQueries({
			results: [pendingOrder({ orderKind: "deposit", amountCents: 6900 })],
		});
		sessionStorage.setItem("order-credential:o1", JSON.stringify({
			type: "qr_code",
			code_url: "weixin://wxpay/x",
		}));

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		// 新时序：开框先查活单（异步）→ 押金单 → consent
		expect(
			await screen.findByTestId("checkout-deposit-consent"),
		).toBeInTheDocument();
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-checkbox"));
		});
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-button"));
		});

		expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
		// 复用活单：不发 createOrder
		expect(client.mutate).not.toHaveBeenCalled();
	});

	it("定价场（无 depositAmountCents）：不出现确认块，直接初始化（回归）", async () => {
		mockQueries({ results: [] });

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
				amountCents={19900}
				tierName="标准档"
			/>,
		);

		// 直接进入支付：无确认块，下单即开始
		expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
		expect(
			screen.queryByTestId("checkout-deposit-consent"),
		).not.toBeInTheDocument();
		expect(client.mutate).toHaveBeenCalledTimes(1);

		// #543：定价场收银框明示退款规则（押金 note 同款形态）
		expect(screen.getByTestId("checkout-pricing-note")).toHaveTextContent(
			"活动开始前取消全额退",
		);
	});

	it("押金场识别按存在性（#686/#748）：paymentMode=deposit 且金额缺失 → 仍停确认态，未勾选零创单", async () => {
		mockQueries(
			{ results: [] },
			{ results: [depositEnrollment({ depositAmountCents: null })] },
		);

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		// 金额缺失（快照 depositAmountCents=null）不影响门：确认块仍出现、
		// 未勾选禁用、零创单
		expect(
			await screen.findByTestId("checkout-deposit-consent"),
		).toBeInTheDocument();
		expect(
			screen.getByTestId("checkout-deposit-consent-button"),
		).toBeDisabled();
		expect(client.mutate).not.toHaveBeenCalled();

		// 创单返回押金单（漂移检测放行）；勾选确认后才创单
		client.mutate.mockResolvedValue({
			data: createOrderPayload({
				result: pendingOrder({ orderKind: "deposit", amountCents: 6900 }),
			}),
		});
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-checkbox"));
		});
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-button"));
		});
		expect(client.mutate).toHaveBeenCalledTimes(1);
		expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
	});

	it("反向断言（#686/#748）：报名快照非押金（paymentMode=pricing）即使金额在场也不出门——识别已脱离金额", async () => {
		mockQueries(
			{ results: [] },
			{ results: [depositEnrollment({ paymentMode: "pricing" })] },
		);

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
		expect(
			screen.queryByTestId("checkout-deposit-consent"),
		).not.toBeInTheDocument();
		expect(client.mutate).toHaveBeenCalledTimes(1);
	});

	// F-06：error 态点渠道（alipay_qr）创单又被后端拒 → 自愈回 consent，
	// 确认按钮沿 alipay_qr 重发，不回落记忆渠道（wechat_native）
	it("自愈保留用户已选渠道：点了 alipay_qr 被拒 → 确认后以 alipay_qr 重发（F-06）", async () => {
		mockQueries({ results: [] });
		localStorage.setItem("cgc:last-payment-provider", "wechat_native");
		client.mutate
			.mockResolvedValueOnce({
				data: {
					createOrder: {
						result: null,
						errors: [
							{
								code: "order_not_payment_pending",
								message: "not pending",
							},
						],
						metadata: null,
					},
				},
			})
			.mockResolvedValueOnce({
				data: {
					createOrder: {
						result: null,
						errors: [
							{
								code: "order_deposit_consent_required",
								message: "deposit consent is required",
							},
						],
						metadata: null,
					},
				},
			})
			.mockResolvedValue({
				data: createOrderPayload({
					result: pendingOrder({ orderKind: "deposit", amountCents: 6900 }),
				}),
			});

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		// 首创（记忆渠道 wechat_native）失败（非押金拒单）→ error 态，渠道按钮在场
		expect(await screen.findByTestId("checkout-error")).toBeInTheDocument();

		// 用户在渠道区点 alipay_qr（无单路径 = 直接以该渠道重发创单）→ 撞押金门 → 自愈回 consent
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-provider-alipay_qr"));
		});
		expect(
			await screen.findByTestId("checkout-deposit-consent"),
		).toBeInTheDocument();

		// 勾选 + 确认：沿 alipay_qr 重发（而非回落记忆渠道 wechat_native）
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-checkbox"));
		});
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-button"));
		});
		await waitFor(() =>
			expect(client.mutate).toHaveBeenLastCalledWith(
				expect.objectContaining({
					variables: {
						input: {
							enrollmentId: "enr-1",
							provider: "alipay_qr",
							depositConsent: true,
						},
					},
				}),
			),
		);
	});
	it("口径漂移（押金身份 → 落定价单）：不出码 + 提示，单留 pending 可重试（F-08）", async () => {
		mockQueries({ results: [] }, { results: [depositEnrollment()] });
		client.mutate.mockResolvedValue({
			data: createOrderPayload(), // 默认 enrollment 单 = 漂移
		});

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		// 押金场停确认态后再操作（初始化查询异步完成）
		await screen.findByTestId("checkout-deposit-consent");

		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-checkbox"));
		});
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-button"));
		});

		expect(await screen.findByTestId("checkout-error")).toHaveTextContent(
			"活动缴费方式刚刚发生变化",
		);
		expect(screen.queryByTestId("checkout-qr")).not.toBeInTheDocument();
		// 单已创建但状态与 UI 分叉最小化：mutate 只发了一次
		expect(client.mutate).toHaveBeenCalledTimes(1);
	});

	// #751-①：busy 同帧锁——disabled 拦不住同帧双击（第二次 click 带旧 state），
	// ref 在第一次进入时即置位，第二次直接返回 → 只有一次创单请求
	it("consent 确认按钮同帧连点：busy ref 拦截，只发一次创单（#751）", async () => {
		mockQueries({ results: [] }, { results: [depositEnrollment()] });
		const { promise, resolve: resolveCreate } =
			Promise.withResolvers<unknown>();
		client.mutate.mockImplementation(() => promise);

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		// 押金场停确认态后再操作（初始化查询异步完成）
		await screen.findByTestId("checkout-deposit-consent");
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-checkbox"));
		});
		const confirm = screen.getByTestId("checkout-deposit-consent-button");
		expect(confirm).toBeEnabled();

		// 同帧双击：两次 click handler 顺序执行，第二次撞 busyRef 返回
		await act(async () => {
			fireEvent.click(confirm);
			fireEvent.click(confirm);
		});
		expect(client.mutate).toHaveBeenCalledTimes(1);

		await act(async () => {
			resolveCreate({
				data: createOrderPayload({
					result: pendingOrder({ orderKind: "deposit", amountCents: 6900 }),
				}),
			});
		});
		expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
	});

	// #750/F-05 自愈：存量押金单换渠道被拒 → 自动带同意重下（补留痕），框内换码
	it("换渠道撞 order_deposit_consent_missing → 自动带同意重新创单（#750 F-05）", async () => {
		mockQueries({ results: [] }, { results: [depositEnrollment()] });
		client.mutate
			.mockResolvedValueOnce({
				data: createOrderPayload({
					result: pendingOrder({ orderKind: "deposit", amountCents: 6900 }),
				}),
			})
			.mockResolvedValueOnce({
				data: {
					replaceProvider: {
						result: null,
						errors: [
							{
								code: "order_deposit_consent_missing",
								message: "no recorded consent",
							},
						],
						metadata: null,
					},
				},
			})
			.mockResolvedValue({
				data: createOrderPayload({
					result: pendingOrder({
						id: "o2",
						orderKind: "deposit",
						amountCents: 6900,
					}),
					metadata: {
						credential: JSON.stringify({
							type: "qr_code",
							code_url: "https://qr.alipay.com/y",
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

		// 押金场停 consent → 勾选确认（首创押金单出码）→ 点 alipay_qr 换渠道
		// → replace 被拒（order_deposit_consent_missing）→ 自愈带同意重下
		await screen.findByTestId("checkout-deposit-consent");
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-checkbox"));
		});
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-button"));
		});
		await screen.findByTestId("checkout-qr");
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-provider-alipay_qr"));
		});

		await waitFor(() =>
			expect(QRCodeStub.toDataURL).toHaveBeenCalledWith(
				"https://qr.alipay.com/y",
				expect.anything(),
			),
		);
		expect(client.mutate).toHaveBeenLastCalledWith(
			expect.objectContaining({
				variables: {
					input: {
						enrollmentId: "enr-1",
						provider: "alipay_qr",
						depositConsent: true,
					},
				},
			}),
		);
		expect(screen.queryByTestId("checkout-error")).not.toBeInTheDocument();
	});
});

describe("payment-checkout-dialog 押金口径绑订单快照（#580）", () => {
	it("组织者关押金后复用押金活单：门仍出现（不零披露），说明行用订单快照金额", async () => {
		// 活动实时配置已非押金（不传 depositAmountCents），但活单是押金单
		mockQueries({
			results: [pendingOrder({ orderKind: "deposit", amountCents: 9900 })],
		});
		sessionStorage.setItem("order-credential:o1", JSON.stringify({
			type: "qr_code",
			code_url: "weixin://wxpay/x",
		}));

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		// 门出现 + 说明行金额 = 订单快照 9900 → ¥99
		expect(
			await screen.findByTestId("checkout-deposit-consent"),
		).toBeInTheDocument();
		expect(screen.getByTestId("checkout-deposit-note")).toHaveTextContent(
			"押金 ¥99（到场退）",
		);
		// 未确认不出码
		expect(screen.queryByTestId("checkout-qr")).not.toBeInTheDocument();
	});

	it("改押金额后复用活单：说明行显示订单快照价而非报名快照现值（不漂移）", async () => {
		// 报名快照（MY_ENROLLMENT）已跟随现值 6900（#749），在途单仍是创单时快照 9900
		mockQueries(
			{ results: [pendingOrder({ orderKind: "deposit", amountCents: 9900 })] },
			{ results: [depositEnrollment({ depositAmountCents: 6900 })] },
		);
		sessionStorage.setItem("order-credential:o1", JSON.stringify({
			type: "qr_code",
			code_url: "weixin://wxpay/x",
		}));

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		expect(await screen.findByTestId("checkout-deposit-consent")).toBeInTheDocument();
		const note = screen.getByTestId("checkout-deposit-note");
		expect(note).toHaveTextContent("押金 ¥99（到场退）");
		expect(note).not.toHaveTextContent("69");
	});

	it("定价活单（orderKind=enrollment）：无押金门无说明行，直接出码", async () => {
		mockQueries({ results: [pendingOrder()] });
		sessionStorage.setItem("order-credential:o1", JSON.stringify({
			type: "qr_code",
			code_url: "weixin://wxpay/x",
		}));

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
				amountCents={19900}
			/>,
		);

		expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
		expect(
			screen.queryByTestId("checkout-deposit-consent"),
		).not.toBeInTheDocument();
		expect(
			screen.queryByTestId("checkout-deposit-note"),
		).not.toBeInTheDocument();
	});

	it("活单 orderKind 未知值：fail-closed 停支付面，不出码不出门", async () => {
		mockQueries({ results: [pendingOrder({ orderKind: "mystery_kind" })] });

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		expect(await screen.findByTestId("checkout-error")).toHaveTextContent(
			"订单缴费口径无法识别",
		);
		expect(screen.queryByTestId("checkout-qr")).not.toBeInTheDocument();
		expect(
			screen.queryByTestId("checkout-deposit-consent"),
		).not.toBeInTheDocument();
	});

	it("创单返回未知 orderKind：fail-closed 停支付面不出码", async () => {
		mockQueries({ results: [] });
		client.mutate.mockResolvedValue({
			data: createOrderPayload({
				result: pendingOrder({ orderKind: "mystery_kind" }),
			}),
		});

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
				amountCents={19900}
			/>,
		);

		expect(await screen.findByTestId("checkout-error")).toHaveTextContent(
			"订单缴费口径无法识别",
		);
		expect(screen.queryByTestId("checkout-qr")).not.toBeInTheDocument();
	});
});
