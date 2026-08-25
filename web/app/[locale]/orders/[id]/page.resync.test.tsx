import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, act } from "@testing-library/react";
import { render } from "@/test-utils";
import OrderDetailPage from "./page";

/**
 * 回归：支付完成后页面必须自动收敛（生产实证 2026-08-24/25）。
 *
 * R14 修订后轮询无死窗：30s 快频后 5s 降频续轮到终态；新标签页跳转支付
 * （alipay_page）场景页面后台 timer 被节流，切回时 focus/visibilitychange
 * 补拉一次即时收敛。两条断言链：
 * 1. 后台停留超 30s → 前台恢复后轮询仍在推进（无「刷新已暂停」手动态）；
 * 2. 支付在后台完成 → 切回 → order-paid 出现。
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

describe("支付完成后自动收敛（降频续轮 + visibilitychange 补拉回归）", () => {
	it("后台支付 30s+（超快频段）→ 切回页面 → 补拉即显示已支付", async () => {
		// 首拉 + 在途轮询全 pending；切回补拉时 paid
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
		// 用户点开支付宝新标签页支付，本页转后台 —— 细粒度推进 35s（超 30s
		// 快频段；1s 步长让快频链充分跑：首拉 + 15 轮 = 16 次 pending）
		for (let i = 0; i < 35; i++) {
			await act(async () => {
				await vi.advanceTimersByTimeAsync(1_000);
			});
		}

		// 无手动态：轮询持续（不渲染「刷新已暂停」）
		expect(screen.queryByTestId("order-manual-mode")).not.toBeInTheDocument();

		// 用户从支付宝切回本页（visibilitychange → visible）
		await act(async () => {
			Object.defineProperty(document, "visibilityState", {
				value: "visible",
				configurable: true,
			});
			document.dispatchEvent(new Event("visibilitychange"));
		});

		// 断言：补拉 + 显示已支付
		expect(
			await screen.findByTestId("order-paid", {}, { timeout: 3000 }),
		).toBeInTheDocument();
	});

	it("前台扫码支付 60s 完成 → 降频续轮自动翻转 paid（无手动刷新）", async () => {
		// 前 17 次查询 pending（首拉 + 快频 15 + 降频 1 ≈ 35s），此后 paid
		let queryCallCount = 0;
		client.query.mockImplementation(async () => {
			queryCallCount += 1;
			return queryCallCount <= 17 ? orderPayload("pending") : orderPayload("paid");
		});

		render(<OrderDetailPage />);
		expect(await screen.findByTestId("order-summary")).toBeInTheDocument();

		// 快频段耗尽后降频续轮（1s 步长推进 75s：快频 30s + 降频 45s ≈ 9 轮，
		// 第 18 次查询起 paid → 页面自动翻转，全程无手动刷新入口）
		for (let i = 0; i < 75; i++) {
			await act(async () => {
				await vi.advanceTimersByTimeAsync(1_000);
			});
		}

		expect(screen.queryByTestId("order-manual-mode")).not.toBeInTheDocument();
		expect(
			await screen.findByTestId("order-paid", {}, { timeout: 3000 }),
		).toBeInTheDocument();
	});
});
