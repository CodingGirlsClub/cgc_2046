import { describe, it, expect } from "vitest";
import {
	POLL_INTERVAL_MS,
	POLL_SLOW_INTERVAL_MS,
	POLL_TOTAL_MS,
	countdownText,
	dispatchCredential,
	formatAmount,
	nextPollTick,
	parsePaymentStats,
	parsePriceTiers,
} from "./payment";

describe("U11 payment 纯逻辑", () => {
	describe("凭据分派（R13）", () => {
		it("wechat_native → 二维码模式（code_url）", () => {
			const credential = JSON.stringify({ type: "qr_code", code_url: "weixin://wxpay/bizpayurl?pr=x" });
			expect(dispatchCredential(credential)).toEqual({
				mode: "qr",
				url: "weixin://wxpay/bizpayurl?pr=x",
			});
		});

		it("alipay page/wap → 跳转模式（url），page 与 wap 同构", () => {
			for (const url of ["https://openapi.alipay.com/gateway.do?x=1", "https://mapi.alipay.com/?y=2"]) {
				expect(dispatchCredential(JSON.stringify({ type: "redirect", url }))).toEqual({
					mode: "redirect",
					url,
				});
			}
		});

		it("jsapi → 不支持（小程序专属，web 引导文案）；对象直传与 JsonString 等价", () => {
			expect(dispatchCredential({ type: "jsapi", pay_params: {} })).toMatchObject({
				mode: "unsupported",
			});
			expect(dispatchCredential(JSON.stringify({ type: "jsapi" }))).toMatchObject({
				mode: "unsupported",
			});
		});

		it("缺失/坏 JSON/未知类型 → unsupported，不 throw", () => {
			expect(dispatchCredential(null)).toMatchObject({ mode: "unsupported" });
			expect(dispatchCredential("not-json")).toMatchObject({ mode: "unsupported" });
			expect(dispatchCredential({ type: "future_mode" })).toMatchObject({ mode: "unsupported" });
		});
	});

	describe("轮询决策（R14 修订：30s 快频 + 降频续轮到终态，无死窗）", () => {
		it("常量：快频 2s、快频段 30s、降频 5s", () => {
			expect(POLL_INTERVAL_MS).toBe(2000);
			expect(POLL_TOTAL_MS).toBe(30000);
			expect(POLL_SLOW_INTERVAL_MS).toBe(5000);
		});

		it("快频段内（<30s）：每轮延迟 2s，未过窗", () => {
			for (const elapsed of [0, 2000, 4000, 28000]) {
				const tick = nextPollTick(elapsed, "pending");
				expect(tick.continue).toBe(true);
				expect(tick.expiredWindow).toBe(false);
				expect(tick.delayMs).toBe(2000);
			}
		});

		it("过 30s 后不停轮：降频 5s 续轮（扫码支付 30~60s+ 真实窗口）", () => {
			for (const elapsed of [30000, 60000, 300000]) {
				const tick = nextPollTick(elapsed, "pending");
				expect(tick.continue).toBe(true);
				expect(tick.expiredWindow).toBe(true);
				expect(tick.delayMs).toBe(5000);
			}
		});

		it("终态即停（paid/refunded/expired 等），无论快频/降频段", () => {
			for (const status of ["paid", "refunded", "expired", "cancelled", "refund_failed", "refunding"] as const) {
				for (const elapsed of [0, 30000, 300000]) {
					const tick = nextPollTick(elapsed, status);
					expect(tick.continue).toBe(false);
					expect(tick.delayMs).toBeNull();
				}
			}
		});
	});

	describe("倒计时", () => {
		const expireAt = "2026-08-16T12:00:00Z";

		it("剩余时间渲染为 mm:ss", () => {
			expect(countdownText(Date.parse("2026-08-16T11:59:30Z"), expireAt, "已过期")).toBe("00:30");
			expect(countdownText(Date.parse("2026-08-16T11:41:05Z"), expireAt, "已过期")).toBe("18:55");
		});

		it("已过期/无效值", () => {
			expect(countdownText(Date.parse("2026-08-16T12:00:01Z"), expireAt, "已过期")).toBe("已过期");
			expect(countdownText(Date.parse("2026-08-16T12:00:00Z"), expireAt, "已过期")).toBe("已过期");
			expect(countdownText(0, null, "已过期")).toBe("—");
			expect(countdownText(0, "not-a-date", "已过期")).toBe("—");
		});
	});

	describe("统计解析（U10 决策 3：JsonString snake_case int 键）", () => {
		it("合法负载 → camelCase 四分量(含 refundFailedCents)", () => {
			expect(
				parsePaymentStats(
					'{"collected_cents":59700,"pending_cents":19900,"refunded_cents":19900,"refund_failed_cents":9900}',
				),
			).toEqual({
				collectedCents: 59700,
				pendingCents: 19900,
				refundedCents: 19900,
				refundFailedCents: 9900,
			});
			// 旧三键负载(前向后向):refund_failed 缺省 0
			expect(
				parsePaymentStats('{"collected_cents":59700,"pending_cents":19900,"refunded_cents":19900}'),
			).toEqual({ collectedCents: 59700, pendingCents: 19900, refundedCents: 19900, refundFailedCents: 0 });
		});

		it("字符串数值/坏负载/空值 → 容错", () => {
			expect(
				parsePaymentStats('{"collected_cents":"59700","pending_cents":0,"refunded_cents":0}'),
			).toEqual({ collectedCents: 59700, pendingCents: 0, refundedCents: 0, refundFailedCents: 0 });
			expect(parsePaymentStats("{broken")).toBeNull();
			expect(parsePaymentStats(null)).toBeNull();
			expect(parsePaymentStats('{"collected_cents":1}')).toBeNull();
		});
	});

	describe("档位与金额", () => {
		it("availablePriceTiers JsonString 数组 → PriceTier[]，非法项丢弃", () => {
			const raw = [
				JSON.stringify({ id: "t1", name: "早鸟", amount_cents: 9900, available_until: null }),
				JSON.stringify({ id: "t2", name: "标准", amount_cents: 19900 }),
				"broken-json",
				JSON.stringify({ id: "t3" }),
			];
			expect(parsePriceTiers(raw)).toEqual([
				{ id: "t1", name: "早鸟", amountCents: 9900, availableUntil: null },
				{ id: "t2", name: "标准", amountCents: 19900, availableUntil: null },
			]);
			expect(parsePriceTiers(null)).toEqual([]);
		});

		it("formatAmount 分 → 元两位小数", () => {
			expect(formatAmount(19900)).toBe("199.00");
			expect(formatAmount(9900)).toBe("99.00");
			expect(formatAmount(1)).toBe("0.01");
		});
	});
});
