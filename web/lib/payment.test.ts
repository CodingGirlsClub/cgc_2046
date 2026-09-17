import { describe, it, expect } from "vitest";
import {
	POLL_INTERVAL_MS,
	POLL_SLOW_INTERVAL_MS,
	POLL_TOTAL_MS,
	countdownText,
	dispatchCredential,
	formatAmount,
	formatAmountShort,
	nextPollTick,
	parsePaymentStats,
	parsePriceTiers,
	positiveAmountOrNull,
	tierSnapshotName,
	truncateOutTradeNo,
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
		it("合法负载 → camelCase 五分量(含 refundFailedCents/forfeitedCents)", () => {
			expect(
				parsePaymentStats(
					'{"collected_cents":59700,"pending_cents":19900,"refunded_cents":19900,"refund_failed_cents":9900,"forfeited_cents":6900}',
				),
			).toEqual({
				collectedCents: 59700,
				pendingCents: 19900,
				refundedCents: 19900,
				refundFailedCents: 9900,
				forfeitedCents: 6900,
			});
			// 旧三键负载(前向后向):refund_failed/forfeited 缺省 0
			expect(
				parsePaymentStats('{"collected_cents":59700,"pending_cents":19900,"refunded_cents":19900}'),
			).toEqual({
				collectedCents: 59700,
				pendingCents: 19900,
				refundedCents: 19900,
				refundFailedCents: 0,
				forfeitedCents: 0,
			});
		});

		it("字符串数值/坏负载/空值 → 容错", () => {
			expect(
				parsePaymentStats('{"collected_cents":"59700","pending_cents":0,"refunded_cents":0}'),
			).toEqual({
				collectedCents: 59700,
				pendingCents: 0,
				refundedCents: 0,
				refundFailedCents: 0,
				forfeitedCents: 0,
			});
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

	describe("成功卡明细（tierSnapshotName / truncateOutTradeNo）", () => {
		it("tierSnapshot JsonString → 档位名；坏 JSON/缺 name/空串 → null", () => {
			expect(
				tierSnapshotName(JSON.stringify({ id: "t1", name: "早鸟票", amount_cents: 9900 })),
			).toBe("早鸟票");
			expect(tierSnapshotName('{"id":"t1"}')).toBeNull();
			expect(tierSnapshotName('{"name":""}')).toBeNull();
			expect(tierSnapshotName("broken-json")).toBeNull();
			expect(tierSnapshotName(null)).toBeNull();
			expect(tierSnapshotName(undefined)).toBeNull();
		});

		it("truncateOutTradeNo：超 16 位中段省略（前 8 … 后 4），短号原样", () => {
			expect(truncateOutTradeNo("2026082500010001234567890123")).toBe(
				"20260825…0123",
			);
			expect(truncateOutTradeNo("T1")).toBe("T1");
			expect(truncateOutTradeNo("1234567890123456")).toBe("1234567890123456");
		});
	});
});

/**
 * #627：参与条件披露的金额守卫。`null`（缺失）与非正（0 / 负，DB CHECK 上线前的
 * 存量脏行）都必须降级为「不表态」，**绝不显示 ¥0**——押金与收费金额锚共用。
 */
describe("展示金额守卫（#627）", () => {
	it("null / undefined / 0 / 负数 / 小数分一律 null（绝不 ¥0）", () => {
		for (const dirty of [null, undefined, 0, -1]) {
			expect(positiveAmountOrNull(dirty)).toBeNull();
		}
		// F3：后端以「分」为整数单位；0.4 这类非整分值经 formatAmountShort 会
		// 四舍五入成 "0.00" → 必须被守卫挡住（Number.isInteger）
		expect(positiveAmountOrNull(0.4)).toBeNull();
		expect(formatAmountShort(0.4)).toBe("0.00");
	});

	it("正整数原样返回；短式格式化整元省略小数", () => {
		expect(positiveAmountOrNull(6900)).toBe(6900);
		expect(formatAmountShort(6900)).toBe("69");
		expect(formatAmountShort(9950)).toBe("99.50");
	});
});
