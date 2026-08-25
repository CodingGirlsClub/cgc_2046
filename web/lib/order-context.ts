/**
 * 订单展示上下文 sessionStorage 交接（订单页成功卡「活动名」行）。
 *
 * orderStatus 不带活动名（Order 无 enrollment→event title 字段，不动后端），
 * 由下单入口在生成/复用订单时按订单 id 写入：
 * - 收银弹框（payment-checkout-dialog）：调用方有 title 上下文即写
 *   （下单/换渠道/复用活单三路径）；
 * - /orders/new：进页守卫 MY_ENROLLMENT 的 targetTitle，createOrder 成功时写。
 * /orders/[id] 进页读取；拿不到（直接进页/跨 tab/无上下文入口）则不渲染
 * 活动名行，不留空行。与 order-credential 同按订单 id 分键，但不读后即焚
 * （凭据有失效语义，活动名只是展示上下文）。
 */

const key = (orderId: string) => `order-context:${orderId}`;

export interface OrderContext {
	title: string | null;
}

/** 读上下文（坏 JSON/缺 title 静默落 null，调用方按行缺失处理） */
export function readOrderContext(orderId: string): OrderContext | null {
	let raw: string | null = null;
	try {
		raw = sessionStorage.getItem(key(orderId));
	} catch {
		return null;
	}
	if (!raw) return null;
	try {
		const parsed: unknown = JSON.parse(raw);
		if (typeof parsed !== "object" || parsed === null) return null;
		const title = (parsed as Record<string, unknown>).title;
		return { title: typeof title === "string" && title !== "" ? title : null };
	} catch {
		return null;
	}
}

/** 写上下文（空标题跳过——没有上下文就不留痕；隐私模式写失败静默） */
export function storeOrderContext(
	orderId: string,
	title: string | null | undefined,
): void {
	if (!title) return;
	try {
		sessionStorage.setItem(key(orderId), JSON.stringify({ title }));
	} catch {
		// ignore private-mode write errors
	}
}
