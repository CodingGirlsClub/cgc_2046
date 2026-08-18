import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import OrderDetailPage from "./page";

const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { client } = vi.hoisted(() => ({ client: { query: vi.fn(), mutate: vi.fn() } }));
const { QRCodeStub } = vi.hoisted(() => ({
	QRCodeStub: { toDataURL: vi.fn() },
}));
const { useParams } = vi.hoisted(() => ({ useParams: vi.fn() }));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@/lib/apollo-client", () => ({ client }));
vi.mock("qrcode", () => ({ default: QRCodeStub }));
vi.mock("next/navigation", () => ({
	useParams,
	// Link（next/link）内部依赖 usePathname；提供 no-op mock
	usePathname: () => "/orders/o1",
	useRouter: () => ({ replace: vi.fn(), push: vi.fn() }),
}));

const expireAt = "2026-08-16T12:00:00Z";

function orderPayload(overrides: Record<string, unknown> = {}) {
	return {
		orderStatus: {
			id: "o1",
			status: "pending",
			transactionId: null,
			expireAt,
			amountCents: 19900,
			provider: "wechat_native",
			...overrides,
		},
	};
}

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
	useParams.mockReturnValue({ id: "o1" });
	QRCodeStub.toDataURL.mockResolvedValue("data:image/png;base64,qr");
	vi.spyOn(Date, "now").mockReturnValue(Date.parse("2026-08-16T11:59:30Z"));
});

afterEach(() => {
	vi.restoreAllMocks();
	cleanup();
});

describe("/orders/[id] 订单页（U11：倒计时/凭据/轮询编排）", () => {
	it("待支付态：倒计时渲染（mm:ss）+ 轮询进行中文案", async () => {
		client.query.mockResolvedValue({ data: orderPayload() });

		render(<OrderDetailPage />);

		expect(await screen.findByTestId("order-countdown")).toHaveTextContent("00:30");
		expect(screen.getByTestId("order-polling")).toBeInTheDocument();
	});

	it("已支付态：paid 成功文案 + 回跳入口，不渲染凭据区", async () => {
		client.query.mockResolvedValue({ data: orderPayload({ status: "paid" }) });

		render(<OrderDetailPage />);

		expect(await screen.findByTestId("order-paid")).toBeInTheDocument();
		expect(screen.queryByTestId("order-credential")).not.toBeInTheDocument();
		expect(screen.queryByTestId("order-switch")).not.toBeInTheDocument();
	});

	it("过期态：名额已释放提示，不渲染二维码", async () => {
		// now 已越过 expire_at
		vi.spyOn(Date, "now").mockReturnValue(Date.parse("2026-08-16T12:00:05Z"));
		client.query.mockResolvedValue({ data: orderPayload() });

		render(<OrderDetailPage />);

		expect(await screen.findByTestId("order-expired-note")).toBeInTheDocument();
		expect(screen.queryByTestId("order-qr")).not.toBeInTheDocument();
	});

	it("二维码凭据（wechat_native）：qrcode dataURL 渲染", async () => {
		client.query.mockResolvedValue({ data: orderPayload() });
		sessionStorage.setItem(
			"order-credential:o1",
			JSON.stringify({ type: "qr_code", code_url: "weixin://wxpay/x" }),
		);

		render(<OrderDetailPage />);

		const qr = await screen.findByTestId("order-qr");
		expect(qr).toHaveAttribute("src", "data:image/png;base64,qr");
		expect(QRCodeStub.toDataURL).toHaveBeenCalledWith("weixin://wxpay/x", expect.anything());
		expect(screen.getByText("使用微信扫码完成支付")).toBeInTheDocument();
	});

	it("二维码凭据（alipay_qr）：按渠道文案「使用支付宝扫一扫完成支付」", async () => {
		client.query.mockResolvedValue({
			data: orderPayload({ provider: "alipay_qr" }),
		});
		sessionStorage.setItem(
			"order-credential:o1",
			JSON.stringify({ type: "qr_code", code_url: "https://qr.alipay.com/x" }),
		);

		render(<OrderDetailPage />);

		await screen.findByTestId("order-qr");
		expect(screen.getByText("使用支付宝扫一扫完成支付")).toBeInTheDocument();
		expect(screen.queryByText("使用微信扫码完成支付")).not.toBeInTheDocument();
	});

	it("刷新后凭据丢失（credential=null + pending）→ 失效提示 + 换渠道按钮 primary", async () => {
		client.query.mockResolvedValue({ data: orderPayload() });

		render(<OrderDetailPage />);

		const unsupported = await screen.findByTestId("order-credential-unsupported");
		expect(unsupported).toHaveTextContent("支付凭据已失效，请更换支付方式重新获取。");
		const switchBtn = screen.getByTestId("switch-alipay_qr");
		expect(switchBtn).toHaveClass("join-button--primary");
	});

	it("跳转凭据（alipay）：渲染前往支付宝按钮（链接指向凭据 url）", async () => {
		client.query.mockResolvedValue({ data: orderPayload({ provider: "alipay_page" }) });
		sessionStorage.setItem(
			"order-credential:o1",
			JSON.stringify({ type: "redirect", url: "https://pay.alipay.com/x" }),
		);

		render(<OrderDetailPage />);

		const link = await screen.findByTestId("order-redirect");
		expect(link).toHaveAttribute("href", "https://pay.alipay.com/x");
		expect(link).toHaveAttribute("target", "_blank");
	});

	it("轮询推进：orderStatus 每 2s 拉一次，paid 即停", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		client.query.mockResolvedValue({ data: orderPayload() });

		render(<OrderDetailPage />);
		await screen.findByTestId("order-polling");

		await vi.advanceTimersByTimeAsync(2100);
		await vi.advanceTimersByTimeAsync(2100);

		await waitFor(() => expect(client.query).toHaveBeenCalledTimes(3));

		client.query.mockResolvedValue({ data: orderPayload({ status: "paid" }) });
		await vi.advanceTimersByTimeAsync(2100);

		await waitFor(() => expect(screen.getByTestId("order-paid")).toBeInTheDocument());
		vi.useRealTimers();
	});

	it("换渠道：replaceProvider 后新凭据渲染", async () => {
		client.query.mockResolvedValue({ data: orderPayload() });
		sessionStorage.setItem(
			"order-credential:o1",
			JSON.stringify({ type: "qr_code", code_url: "weixin://wxpay/x" }),
		);

		render(<OrderDetailPage />);
		await screen.findByTestId("order-qr");

		client.mutate.mockResolvedValue({
			data: {
				replaceProvider: {
					result: orderPayload().orderStatus,
					errors: [],
					metadata: {
						credential: JSON.stringify({ type: "redirect", url: "https://pay.alipay.com/y" }),
					},
				},
			},
		});

		fireEvent.click(screen.getByTestId("switch-alipay_qr"));

		await waitFor(() =>
			expect(screen.getByTestId("order-redirect")).toHaveAttribute(
				"href",
				"https://pay.alipay.com/y",
			),
		);
	});
	it("换渠道候选单源派生：未签约渠道不在候选，签约集内排除当前", async () => {
		client.query.mockResolvedValue({ data: orderPayload() });

		render(<OrderDetailPage />);

		await screen.findByTestId("order-detail");
		// wechat_native 单 → 候选只有 alipay_qr；未签约 alipay_page/wap 不在
		expect(screen.getByTestId("switch-alipay_qr")).toBeInTheDocument();
		expect(screen.queryByTestId("switch-alipay_page")).not.toBeInTheDocument();
		expect(screen.queryByTestId("switch-alipay_wap")).not.toBeInTheDocument();
	});

	it("换渠道错误经翻译层：provider_not_configured 裸原子 → 人话", async () => {
		client.query.mockResolvedValue({ data: orderPayload() });
		sessionStorage.setItem(
			"order-credential:o1",
			JSON.stringify({ type: "qr_code", code_url: "weixin://wxpay/x" }),
		);

		render(<OrderDetailPage />);
		await screen.findByTestId("order-qr");

		client.mutate.mockResolvedValue({
			data: {
				replaceProvider: {
					result: null,
					errors: [{ code: "order_provider_not_configured" }],
					metadata: null,
				},
			},
		});

		fireEvent.click(screen.getByTestId("switch-alipay_qr"));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"该支付渠道暂未开通，请选择其他方式。",
		);
	});
});
