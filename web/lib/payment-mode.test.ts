import { describe, expect, it } from "vitest";
import {
	COURSE_PAYMENT_MODES,
	PAYMENT_MODES,
	depositAmountDraft,
	depositAmountToCents,
	paymentModeOf,
	paymentSlotChanged,
	paymentSlotPayload,
} from "./payment-mode";

/**
 * 缴费槽三态单源（U9/KTD10/R1/R10）：payload 字段互斥 + 脏检查。
 *
 * 互斥是资金口径：押金态下发 pricingEnabled=false + priceTiers=[]，
 * 定价态下发 depositEnabled=false + depositAmountCents=null；两端同真只有
 * 后端 DB CHECK 拦截的份（`event_payment_mode_exclusive`），UI 不制造该提交。
 */

const TIERS = [JSON.stringify({ id: "t1", name: "标准", amount_cents: 19900 })];

describe("paymentModeOf 资源态映射", () => {
	it("押金优先于定价（两列同真不可达，仍取押金）", () => {
		expect(paymentModeOf({ depositEnabled: true, pricingEnabled: false })).toBe(
			"deposit",
		);
		expect(paymentModeOf({ depositEnabled: true, pricingEnabled: true })).toBe(
			"deposit",
		);
	});

	it("定价 / 免费 / 缺省 / null 各归其位", () => {
		expect(paymentModeOf({ pricingEnabled: true })).toBe("pricing");
		expect(paymentModeOf({ pricingEnabled: false })).toBe("free");
		expect(paymentModeOf({})).toBe("free");
		expect(
			paymentModeOf({ pricingEnabled: null, depositEnabled: null }),
		).toBe("free");
	});
});

describe("paymentSlotPayload 三态序列化", () => {
	it("event 免费：清定价档位、清押金金额", () => {
		expect(
			paymentSlotPayload({
				kind: "event",
				mode: "free",
				tiers: TIERS,
				depositAmountCents: 6900,
			}),
		).toEqual({
			pricingEnabled: false,
			priceTiers: [],
			depositEnabled: false,
			depositAmountCents: null,
		});
	});

	it("event 定价：档位随行、押金清空（互斥双向）", () => {
		expect(
			paymentSlotPayload({
				kind: "event",
				mode: "pricing",
				tiers: TIERS,
				depositAmountCents: 6900,
			}),
		).toEqual({
			pricingEnabled: true,
			priceTiers: TIERS,
			depositEnabled: false,
			depositAmountCents: null,
		});
	});

	it("event 押金：金额为分、档位清空", () => {
		expect(
			paymentSlotPayload({
				kind: "event",
				mode: "deposit",
				tiers: TIERS,
				depositAmountCents: 6900,
			}),
		).toEqual({
			pricingEnabled: false,
			priceTiers: [],
			depositEnabled: true,
			depositAmountCents: 6900,
		});
	});

	it("course：无押金列，任何态都不下发 deposit 键（否则 GraphQL 输入校验拒绝）", () => {
		const payload = paymentSlotPayload({
			kind: "course",
			mode: "pricing",
			tiers: TIERS,
			depositAmountCents: null,
		});
		expect(payload).toEqual({ pricingEnabled: true, priceTiers: TIERS });
		expect(payload).not.toHaveProperty("depositEnabled");
		expect(payload).not.toHaveProperty("depositAmountCents");
	});

	it("三态互斥不变量：任一态下 pricingEnabled 与 depositEnabled 不同真", () => {
		for (const mode of PAYMENT_MODES) {
			const payload = paymentSlotPayload({
				kind: "event",
				mode,
				tiers: TIERS,
				depositAmountCents: 6900,
			});
			expect(payload.pricingEnabled && payload.depositEnabled).toBe(false);
		}
	});

	it("course 态集合不含押金（两态退化）", () => {
		expect(COURSE_PAYMENT_MODES).toEqual(["free", "pricing"]);
		expect(COURSE_PAYMENT_MODES).not.toContain("deposit");
	});
});

describe("押金金额元/分转换", () => {
	it("整元与角分各按分落库", () => {
		expect(depositAmountToCents("69")).toBe(6900);
		expect(depositAmountToCents("69.5")).toBe(6950);
		expect(depositAmountToCents(" 0.01 ")).toBe(1);
	});

	it("空 / 非数 / 非正 / 不足 1 分 → null（表单层拦截不提交）", () => {
		expect(depositAmountToCents("")).toBeNull();
		expect(depositAmountToCents("  ")).toBeNull();
		expect(depositAmountToCents("abc")).toBeNull();
		expect(depositAmountToCents("0")).toBeNull();
		expect(depositAmountToCents("-5")).toBeNull();
		expect(depositAmountToCents("0.001")).toBeNull();
	});

	it("回填草稿：分 → 元（null/undefined → 空串）", () => {
		expect(depositAmountDraft(6900)).toBe("69");
		expect(depositAmountDraft(6950)).toBe("69.5");
		expect(depositAmountDraft(null)).toBe("");
		expect(depositAmountDraft(undefined)).toBe("");
	});
});

describe("paymentSlotChanged 脏检查（F7：未变不下发缴费键）", () => {
	const server = {
		pricingEnabled: false,
		depositEnabled: false,
		depositAmountCents: null,
	};

	it("档位变更 → 脏（由调用方的 pricingDirty 传位）", () => {
		expect(
			paymentSlotChanged({
				kind: "event",
				server,
				mode: "free",
				depositAmountCents: null,
				pricingDirty: true,
			}),
		).toBe(true);
	});

	it("免费场仅改标题 → 不脏（普通元数据保存不回写缴费配置）", () => {
		expect(
			paymentSlotChanged({
				kind: "event",
				server,
				mode: "free",
				depositAmountCents: null,
				pricingDirty: false,
			}),
		).toBe(false);
	});

	it("开押金 / 关押金 / 改金额 → 脏", () => {
		expect(
			paymentSlotChanged({
				kind: "event",
				server,
				mode: "deposit",
				depositAmountCents: 6900,
				pricingDirty: false,
			}),
		).toBe(true);

		expect(
			paymentSlotChanged({
				kind: "event",
				server: { ...server, depositEnabled: true, depositAmountCents: 6900 },
				mode: "free",
				depositAmountCents: null,
				pricingDirty: false,
			}),
		).toBe(true);

		expect(
			paymentSlotChanged({
				kind: "event",
				server: { ...server, depositEnabled: true, depositAmountCents: 6900 },
				mode: "deposit",
				depositAmountCents: 9900,
				pricingDirty: false,
			}),
		).toBe(true);
	});

	it("押金值未变 → 不脏（幂等保存不下发缴费键）", () => {
		expect(
			paymentSlotChanged({
				kind: "event",
				server: { ...server, depositEnabled: true, depositAmountCents: 6900 },
				mode: "deposit",
				depositAmountCents: 6900,
				pricingDirty: false,
			}),
		).toBe(false);
	});

	it("course 无押金槽：押金位不参与判定", () => {
		expect(
			paymentSlotChanged({
				kind: "course",
				server: { depositEnabled: true, depositAmountCents: 6900 },
				mode: "pricing",
				depositAmountCents: null,
				pricingDirty: false,
			}),
		).toBe(false);
	});
});
