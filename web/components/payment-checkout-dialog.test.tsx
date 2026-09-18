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
    // React 18 passive effect 异步调度：paid 态 DOM 渲染与 onPaid effect 执行
    // 之间可被事件循环拆开（CI 慢机器上曾撞进窗口），waitFor 消除时序敏感
    await waitFor(() => expect(onPaid).toHaveBeenCalledTimes(1));

    // 1.5s 后自动关闭
    await vi.advanceTimersByTimeAsync(1600);
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
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

describe("payment-checkout-dialog 押金支付前确认（U1：以到场为退还条件）", () => {
	it("押金场（无活单）：开框查活单后停确认态——未勾选时确认按钮禁用、零创单、无二维码", async () => {
		client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
				depositEnabled
				depositAmountCents={6900}
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
	// 合并后识别走存在性 depositEnabled（#686），金额（含脏值）不参与识别：
	// 押金场 + 脏金额 → 披露门照常出现，不 fail-open 成非押金口径。
	it.each([
		["0", 0],
		["非整数分", 0.4],
	])("押金金额脏（%s）：披露门仍在（不 fail-open），说明行落待定、框头无 ¥0", async (_label, dirty) => {
		client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
				depositEnabled
				depositAmountCents={dirty}
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
		client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
				depositEnabled
				depositAmountCents={6900}
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

	it("押金场 + 后端拒单（识别缺失的 fail-open 类）→ 自愈回 consent 补勾选（#727）", async () => {
		// 调用方漏传 depositEnabled（#686 fail-open 类）→ 直接创单不带 consent
		client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });
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

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
				depositAmountCents={6900}
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

		// 自愈：不落死 error 态，就地出披露 + 勾选（披露行金额取调用方给的押金金额）
		expect(
			await screen.findByTestId("checkout-deposit-consent"),
		).toBeInTheDocument();
		expect(screen.getByTestId("checkout-deposit-note")).toHaveTextContent(
			"押金 ¥69（到场退）",
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
		client.query.mockResolvedValue({
			data: {
				myOrders: { results: [pendingOrder({ orderKind: "deposit", amountCents: 6900 })] },
			},
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
				depositEnabled
				depositAmountCents={6900}
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
		client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

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

	it("押金场识别按存在性（#686）：depositEnabled 且金额缺失 → 仍停确认态，未勾选零创单", async () => {
		client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
				depositEnabled
			/>,
		);

		// 金额缺失（未传 depositAmountCents）不影响门：确认块仍出现、未勾选禁用、零创单
		expect(
			await screen.findByTestId("checkout-deposit-consent"),
		).toBeInTheDocument();
		expect(
			screen.getByTestId("checkout-deposit-consent-button"),
		).toBeDisabled();
		expect(client.mutate).not.toHaveBeenCalled();

		// 勾选确认后才创单
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-checkbox"));
		});
		await act(async () => {
			fireEvent.click(screen.getByTestId("checkout-deposit-consent-button"));
		});
		expect(client.mutate).toHaveBeenCalledTimes(1);
		expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
	});

	it("单变量对照（#686）：缺 depositEnabled → 视为非押金场，无确认块直接创单", async () => {
		client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
			/>,
		);

		// 不出同意门、直接进支付面（单拿走存在性事实，其余一字不动）
		expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
		expect(
			screen.queryByTestId("checkout-deposit-consent"),
		).not.toBeInTheDocument();
		expect(client.mutate).toHaveBeenCalledTimes(1);
	});

	it("反向断言（#686）：非押金场（depositEnabled=false）即使押金金额在场也不出门——识别已脱离金额", async () => {
		client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });

		render(
			<PaymentCheckoutDialog
				enrollmentId="enr-1"
				onClose={vi.fn()}
				onPaid={vi.fn()}
				depositEnabled={false}
				depositAmountCents={6900}
			/>,
		);

		expect(await screen.findByTestId("checkout-qr")).toBeInTheDocument();
		expect(
			screen.queryByTestId("checkout-deposit-consent"),
		).not.toBeInTheDocument();
		expect(client.mutate).toHaveBeenCalledTimes(1);
	});
});

describe("payment-checkout-dialog 押金口径绑订单快照（#580）", () => {
	it("组织者关押金后复用押金活单：门仍出现（不零披露），说明行用订单快照金额", async () => {
		// 活动实时配置已非押金（不传 depositAmountCents），但活单是押金单
		client.query.mockResolvedValue({
			data: {
				myOrders: { results: [pendingOrder({ orderKind: "deposit", amountCents: 9900 })] },
			},
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

	it("改押金额后复用活单：说明行显示订单快照价而非活动现价（不漂移）", async () => {
		// 活动现价已下调到 6900，在途单仍是报名时快照 9900
		client.query.mockResolvedValue({
			data: {
				myOrders: { results: [pendingOrder({ orderKind: "deposit", amountCents: 9900 })] },
			},
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
				depositAmountCents={6900}
			/>,
		);

		expect(await screen.findByTestId("checkout-deposit-consent")).toBeInTheDocument();
		const note = screen.getByTestId("checkout-deposit-note");
		expect(note).toHaveTextContent("押金 ¥99（到场退）");
		expect(note).not.toHaveTextContent("69");
	});

	it("定价活单（orderKind=enrollment）：无押金门无说明行，直接出码", async () => {
		client.query.mockResolvedValue({
			data: { myOrders: { results: [pendingOrder()] } },
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
		client.query.mockResolvedValue({
			data: {
				myOrders: { results: [pendingOrder({ orderKind: "mystery_kind" })] },
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
			"订单缴费口径无法识别",
		);
		expect(screen.queryByTestId("checkout-qr")).not.toBeInTheDocument();
		expect(
			screen.queryByTestId("checkout-deposit-consent"),
		).not.toBeInTheDocument();
	});

	it("创单返回未知 orderKind：fail-closed 停支付面不出码", async () => {
		client.query.mockResolvedValue({ data: { myOrders: { results: [] } } });
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
