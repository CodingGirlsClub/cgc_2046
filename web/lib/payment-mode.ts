import type { OfferingKind } from "./graphql/events";

/**
 * Event 缴费槽三态（event-deposit U9 / KTD10 / R1 / R3 / R10）。
 *
 * 免费 / 定价档位 / 押金三态互斥（R1）：同一场只一种。本模块是「三态 → mutation
 * 缴费键」的唯一序列化点——押金态清空档位、定价态清空押金，字段互斥由构造保证
 * （后端 `PaymentModeValidation` 与 DB CHECK `events_payment_mode_exclusive` 兜底，
 * 并发/绕过 UI 时返回 `event_payment_mode_exclusive`）。
 *
 * course 无押金槽（courses 表无 deposit 列）：三态退化为两态，误传 deposit 键
 * 会被 GraphQL 输入校验拒绝，故按 kind 剥离。
 */

export type PaymentMode = "free" | "pricing" | "deposit";

/** 三态选择顺序（event） */
export const PAYMENT_MODES: PaymentMode[] = ["free", "pricing", "deposit"];

/** 两态选择顺序（course，无押金） */
export const COURSE_PAYMENT_MODES: PaymentMode[] = ["free", "pricing"];

/** 三态标签（i18n 键，offerings namespace） */
export const PAYMENT_MODE_LABEL: Record<PaymentMode, string> = {
	free: "paymentModeFree",
	pricing: "paymentModePricing",
	deposit: "paymentModeDeposit",
};

/** 资源当前态 → 三态（deposit 优先；两列互斥由后端保证，同时为真不可达） */
export function paymentModeOf(item: {
	pricingEnabled?: boolean | null;
	depositEnabled?: boolean | null;
}): PaymentMode {
	if (item.depositEnabled === true) return "deposit";
	return item.pricingEnabled === true ? "pricing" : "free";
}

/** 押金金额元输入 → 分；空/非数/≤0 或不足 1 分 → null（表单层拦截不提交） */
export function depositAmountToCents(input: string): number | null {
	const yuan = Number(input.trim());
	if (input.trim() === "" || !Number.isFinite(yuan) || yuan <= 0) return null;
	const cents = Math.round(yuan * 100);
	return cents < 1 ? null : cents;
}

/** 押金金额分 → 元草稿（编辑面回填；null → 空串） */
export function depositAmountDraft(cents: number | null | undefined): string {
	return cents == null ? "" : String(cents / 100);
}

/** mutation 缴费键（三态互斥单源） */
export interface PaymentSlotPayload {
	pricingEnabled: boolean;
	priceTiers: string[];
	depositEnabled?: boolean;
	depositAmountCents?: number | null;
}

/**
 * 三态 → mutation 缴费键：
 * - 免费：pricing=false / tiers 清空 / deposit=false / 金额 null
 * - 定价：pricing=true / tiers / deposit=false / 金额 null
 * - 押金：pricing=false / tiers 清空 / deposit=true / 金额（分）
 */
export function paymentSlotPayload(args: {
	kind: OfferingKind;
	mode: PaymentMode;
	/** 已序列化档位（caller-serializes，PriceTier JSON） */
	tiers: string[];
	depositAmountCents: number | null;
}): PaymentSlotPayload {
	const { kind, mode, tiers, depositAmountCents } = args;
	const pricingEnabled = mode === "pricing";
	const depositEnabled = mode === "deposit";

	return {
		pricingEnabled,
		priceTiers: pricingEnabled ? tiers : [],
		...(kind === "event"
			? {
					depositEnabled,
					depositAmountCents: depositEnabled ? depositAmountCents : null,
				}
			: {}),
	};
}

/**
 * 缴费槽是否相对服务端快照变更（F7 脏检查纪律：未变不下发缴费键，
 * 避免普通元数据保存把陈旧管理员读到的缴费配置一并回写）。
 */
export function paymentSlotChanged(args: {
	kind: OfferingKind;
	server: {
		pricingEnabled?: boolean | null;
		depositEnabled?: boolean | null;
		depositAmountCents?: number | null;
	};
	mode: PaymentMode;
	depositAmountCents: number | null;
	/** 定价开关或档位草稿相对快照的差异（组件内沿用 toDraft 比较） */
	pricingDirty: boolean;
}): boolean {
	if (args.pricingDirty) return true;
	// course 无押金槽：两态由 pricingDirty 全权承担
	if (args.kind !== "event") return false;
	if ((args.server.depositEnabled === true) !== (args.mode === "deposit")) {
		return true;
	}
	return (
		args.mode === "deposit" &&
		(args.server.depositAmountCents ?? null) !== args.depositAmountCents
	);
}
