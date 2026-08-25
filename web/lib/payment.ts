/**
 * 缴费闭环 web 端纯逻辑（plan 024 U11/KTD10）：轮询、凭据分派、统计解析、
 * 金额与倒计时格式化。全部无副作用纯函数，页面只做编排。
 *
 * - 轮询契约（R14）：2s 间隔 × 30s 总窗（15 次），终态即停；超窗转手动刷新态。
 * - 凭据分派（R13）：wechat_native → 二维码（code_url）；alipay_page/wap →
 *   跳转（url）；wechat_jsapi 仅小程序，web 收到视为不支持。
 * - workspacePaymentStats 返回 JsonString（U10 决策 3：三个 snake_case int 键），
 * 此处统一解析为 camelCase。
 */
import type { PaymentProvider } from "./graphql/orders";

/* ---------------- 轮询（R14 修订：2s×30s 快收敛 + 5s 降频续轮到终态） ---------------- */

export const POLL_INTERVAL_MS = 2_000;
export const POLL_TOTAL_MS = 30_000;
/** 30s 窗后的降频间隔（扫码支付真实耗时 30~60s+，页面前台续轮到终态） */
export const POLL_SLOW_INTERVAL_MS = 5_000;

/** 轮询推进的订单状态（终态即停；pending 继续轮） */
export type OrderPollStatus =
	| "pending"
	| "paid"
	| "refunding"
	| "refunded"
	| "refund_failed"
	| "cancelled"
	| "expired";

const POLL_TERMINAL: Record<string, true> = {
	paid: true,
	refunding: true,
	refunded: true,
	refund_failed: true,
	cancelled: true,
	expired: true,
};

export interface PollDecision {
	/** 继续下一轮 */
	continue: boolean;
	/** 本轮后的累计耗时是否已过快频段（30s）——仅降频信号，不再停轮 */
	expiredWindow: boolean;
	/** 下一轮延迟；continue=false 时为 null */
	delayMs: number | null;
}

/**
 * 轮询决策：elapsed + status → 是否继续 / 本轮延迟。
 * 30s 内 2s 一轮（支付完成秒级收敛），之后 5s 降频续轮到终态——
 * 纯函数（fake timers 测试面）；调用方 setTimeout 编排。
 *
 * 生产实证（2026-08-24/25）：扫码支付掏手机→解锁→打开 App→扫码→确认
 * 平均 30~60s，旧 30s 死窗大概率命中「自动确认已暂停」手动态，用户付完
 * 钱回来还要手动刷新；跳转支付（新标签页）场景另有 visibilitychange 补拉，
 * 扫码场景页面前台，只有续轮能收敛。
 */
export function nextPollTick(
	elapsedMs: number,
	status: OrderPollStatus,
	nowMs: number = Date.now(),
): PollDecision {
	const expiredWindow = elapsedMs >= POLL_TOTAL_MS;

	if (POLL_TERMINAL[status]) {
		return { continue: false, expiredWindow, delayMs: null };
	}

	// 纯函数纪律：nowMs 参数化，不内嵌 Date.now（测试确定性）
	void nowMs;
	return {
		continue: true,
		expiredWindow,
		delayMs: expiredWindow ? POLL_SLOW_INTERVAL_MS : POLL_INTERVAL_MS,
	};
}

/* ---------------- 凭据分派（R13） ---------------- */

export type UnsupportedCredentialReason =
	| "invalid"
	| "missing"
	| "unknown"
	| "wechat_jsapi";

export type CredentialDispatch =
	| { mode: "qr"; url: string }
	| { mode: "redirect"; url: string }
	| { mode: "unsupported"; reason: UnsupportedCredentialReason };

/** 不支持的凭据 reason → labels 词表 key（调用方经根 useTranslations 消费） */
export const CREDENTIAL_REASON_LABEL: Record<UnsupportedCredentialReason, string> = {
	invalid: "labels.credentialReason.invalid",
	missing: "labels.credentialReason.missing",
	unknown: "labels.credentialReason.unknown",
	wechat_jsapi: "labels.credentialReason.wechat_jsapi",
};

/**
 * createOrder/replaceProvider metadata.credential（JsonString → 对象）分派：
 * - qr_code（wechat_native）：前端渲染二维码，用户扫码支付；
 * - redirect（alipay_page/wap）：window 跳转；
 * - jsapi（wechat_jsapi）：小程序专属凭据，web 端不支持（引导去小程序）。
 */
export function dispatchCredential(
	credential: unknown,
): CredentialDispatch {
	if (typeof credential === "string") {
		try {
			return dispatchCredential(JSON.parse(credential));
		} catch {
			return { mode: "unsupported", reason: "invalid" };
		}
	}

	if (typeof credential !== "object" || credential === null) {
		return { mode: "unsupported", reason: "missing" };
	}

	const c = credential as Record<string, unknown>;
	const type = typeof c.type === "string" ? c.type : "";

	if (type === "qr_code" && typeof c.code_url === "string" && c.code_url) {
		return { mode: "qr", url: c.code_url };
	}

	if (type === "redirect" && typeof c.url === "string" && c.url) {
		return { mode: "redirect", url: c.url };
	}

	if (type === "jsapi") {
		return { mode: "unsupported", reason: "wechat_jsapi" };
	}

	return { mode: "unsupported", reason: "unknown" };
}

/* ---------------- 统计解析（U10 决策 3：JsonString snake_case int 键） ---------------- */

export interface PaymentStats {
	collectedCents: number;
	pendingCents: number;
	refundedCents: number;
	/** 退款失败待处理（U1-R1；旧负载缺键时 = 0） */
	refundFailedCents: number;
}

export function parsePaymentStats(raw: string | null | undefined): PaymentStats | null {
	if (!raw) return null;

	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch {
		return null;
	}

	if (typeof parsed !== "object" || parsed === null) return null;

	const o = parsed as Record<string, unknown>;
	const toInt = (v: unknown): number | null =>
		typeof v === "number" && Number.isFinite(v)
			? v
			: typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))
				? Number(v)
				: null;

	const collected = toInt(o.collected_cents);
	const pending = toInt(o.pending_cents);
	const refunded = toInt(o.refunded_cents);
	// U1-R1 前向后向：旧三键负载的 refund_failed_cents 缺省 0
	const refundFailed = toInt(o.refund_failed_cents) ?? 0;

	if (collected === null || pending === null || refunded === null) return null;

	return {
		collectedCents: collected,
		pendingCents: pending,
		refundedCents: refunded,
		refundFailedCents: refundFailed,
	};
}

/* ---------------- 价格档位（R1/R2：JsonString 数组） ---------------- */

export interface PriceTier {
	id: string;
	name: string;
	amountCents: number;
	availableUntil: string | null;
}

/** availablePriceTiers（后端已过滤过期档）逐项解析；非法项静默丢弃 */
export function parsePriceTiers(raw: string[] | null | undefined): PriceTier[] {
	if (!Array.isArray(raw)) return [];

	return raw.flatMap((item) => {
		try {
			const t: unknown = JSON.parse(item);
			if (typeof t !== "object" || t === null) return [];
			const o = t as Record<string, unknown>;
			if (typeof o.id !== "string" || typeof o.name !== "string") return [];
			if (typeof o.amount_cents !== "number" || !Number.isFinite(o.amount_cents)) return [];
			return [
				{
					id: o.id,
					name: o.name,
					amountCents: o.amount_cents,
					availableUntil:
						typeof o.available_until === "string" ? o.available_until : null,
				},
			];
		} catch {
			return [];
		}
	});
}

/* ---------------- 展示格式化 ---------------- */

/** 分 → 元（两位小数，R20 存储一律分） */
export function formatAmount(cents: number): string {
	return (cents / 100).toFixed(2);
}

/**
 * web 端已签约可下单渠道（单源：下单页渠道列表 enabled 判定与订单页换渠道
 * 候选共用）。签约新渠道后在此增删；alipay_page/alipay_wap 未签约暂缺。
 */
export const WEB_ENABLED_PROVIDERS: readonly PaymentProvider[] = [
	"wechat_native",
	"alipay_qr",
];

/** 支付渠道展示名（详情/列表/订单页共用单源） */
export const PROVIDER_LABEL: Record<string, string> = {
	wechat_jsapi: "labels.provider.wechat_jsapi",
	wechat_native: "labels.provider.wechat_native",
	alipay_page: "labels.provider.alipay_page",
	alipay_wap: "labels.provider.alipay_wap",
	alipay_qr: "labels.provider.alipay_qr",
};

/** 订单状态徽章词表（participations/订单页/管理列表共用单源） */
export const ORDER_STATUS_LABEL: Record<string, string> = {
	pending: "labels.orderStatus.pending",
	paid: "labels.orderStatus.paid",
	refunding: "labels.orderStatus.refunding",
	refunded: "labels.orderStatus.refunded",
	refund_failed: "labels.orderStatus.refund_failed",
	cancelled: "labels.orderStatus.cancelled",
	expired: "labels.orderStatus.expired",
};

/** 倒计时文案：expire_at − now；过期文案由调用方传翻译（expiredLabel） */
export function countdownText(
	nowMs: number,
	expireAt: string | null | undefined,
	expiredLabel: string,
): string {
	if (!expireAt) return "—";
	const end = new Date(expireAt).getTime();
	if (Number.isNaN(end)) return "—";
	const remain = end - nowMs;
	if (remain <= 0) return expiredLabel;
	const totalSec = Math.floor(remain / 1000);
	const mm = Math.floor(totalSec / 60);
	const ss = totalSec % 60;
	return `${String(mm).padStart(2, "0")}:${String(ss).padStart(2, "0")}`;
}
