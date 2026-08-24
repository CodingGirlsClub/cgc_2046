import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, act } from "@testing-library/react";
import { render } from "@/test-utils";
import OrderDetailPage from "./page";

/**
 * 回归：支付宝（新标签页跳转支付）支付完成后切回页面必须自动收敛（生产
 * 实证 2026-08-24：支付期间页面后台停留超 30s 轮询窗转手动态，切回后
 * 停在「刷新已暂停」显示待支付，手动刷新才恢复）。
 *
 * 修复：focus/visibilitychange 补拉（poll.reset + fetchStatus），
 * 先例 = 工作台首联等待监听。红绿锚定：切回后 order-paid 必须出现。
 */

const { client } = vi.hoisted(() => ({ client: { query: vi.fn(), mutate: vi.fn() } }));
const { QRCodeStub } = vi.hoisted(() => ({
	QRCodeStub: { toDataURL: vi.fn() },
}));
const { useParams } = vi.hoisted(() => ({ useParams: vi.fn() }));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));

vi.mock("@/lib/payment-errors", async () => {
	const messages = (await import("../../../../messages/zh-CN.json")).default;
	const errors = messages.errors as Record<string, string>;
	const translate = (code: string | null | undefined, fallback: string): string =>
		!code ? fallback : (errors[code] ?? fallback);
	return {
		usePaymentErrorTranslator: () => translate,
	};
});
vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@/lib/apollo-client", () => ({ client }));
vi.mock("qrcode", () => ({ default: QRCodeStub }));
vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useParams,
	usePathname: () => "/orders/o1",
	useRouter: () => ({ replace: vi.fn(), push: vi.fn() }),
}));

const expireAt = new Date(Date.now() + 3600_000).toISOString();

function orderPayload(status: string) {
	return {
		data: {
			orderStatus: {
				id: "o1",
				status,
				transactionId: null,
				expireAt,
				amountCents: 19900,
				provider: "alipay_page",
			},
		},
	};
}

beforeEach(() => {
	vi.useFakeTimers({ shouldAdvanceTime: true });
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
	useParams.mockReturnValue({ id: "o1" });
	QRCodeStub.toDataURL.mockResolvedValue("data:image/png;base64,qr");
});

afterEach(() => {
	vi.useRealTimers();
	cleanup();
});

describe("支付完成后切回页面自动收敛（visibilitychange 补拉回归）", () => {
	it("后台支付 30s+ 轮询超窗 → 用户切回页面 → 必须自动补拉并显示已支付", async () => {
		// 首拉 + 轮询窗内 15 轮全 pending（支付在途）；此后（切回补拉）paid
		let queryCallCount = 0;
		client.query.mockImplementation(async () => {
			queryCallCount += 1;
			return queryCallCount <= 16 ? orderPayload("pending") : orderPayload("paid");
		});

		render(<OrderDetailPage />);

		// 首拉完成：订单卡可见（pending 标题）即已进入轮询编排
		expect(await screen.findByTestId("order-summary")).toBeInTheDocument();
		expect(
			screen.queryByTestId("order-detail")?.textContent ?? "",
		).toContain("19");

		// 用户点开支付宝新标签页支付，本页转后台 —— 推进 35s（超 30s 轮询窗）
		for (let i = 0; i < 15; i++) {
			await act(async () => {
				await vi.advanceTimersByTimeAsync(5_000);
			});
		}

		// 轮询窗耗尽 → 手动态（真实用户在此期间完成支付）
		expect(screen.getByTestId("order-manual-mode")).toBeInTheDocument();

		// 用户从支付宝切回本页（visibilitychange → visible）
		await act(async () => {
			Object.defineProperty(document, "visibilityState", {
				value: "visible",
				configurable: true,
			});
			document.dispatchEvent(new Event("visibilitychange"));
		});

		// 断言：页面应自动补拉并显示已支付（当前实现无此逻辑 → 红）
		expect(
			await screen.findByTestId("order-paid", {}, { timeout: 3000 }),
		).toBeInTheDocument();
		expect(screen.queryByTestId("order-manual-mode")).not.toBeInTheDocument();
	});
});
