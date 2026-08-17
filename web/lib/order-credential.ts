/**
 * 支付凭据 sessionStorage 交接单源（plan 024 R13 配套）。
 *
 * createOrder/replaceProvider 返回的 metadata.credential（JsonString）不落
 * URL，经 sessionStorage 按订单 id 交接。三个消费方：
 * - /orders/new：下单成功 → store，replace 跳 /orders/[id]；
 * - /orders/[id]：进页 read + discard（读后即焚——刷新后凭据即失效，pending
 *   态走「换渠道恢复」引导，见订单页 credentialLost 分支）；
 * - 收银模态框（payment-checkout-dialog）：下单/换渠道 → store；复用活单 →
 *   read 但不 discard（模态框可反复开关，且 /orders/[id] 兜底路径仍需凭据）。
 */

const key = (orderId: string) => `order-credential:${orderId}`;

/** 读凭据（坏 JSON 静默落 null，交由 dispatchCredential 的 unsupported 分派） */
export function readOrderCredential(orderId: string): unknown {
  let raw: string | null = null;
  try {
    raw = sessionStorage.getItem(key(orderId));
  } catch {
    return null;
  }
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

/** 存凭据（null/空串跳过；隐私模式写失败静默） */
export function storeOrderCredential(
  orderId: string,
  credential: string | null | undefined,
): void {
  if (!credential) return;
  try {
    sessionStorage.setItem(key(orderId), credential);
  } catch {
    // ignore private-mode write errors
  }
}

/** 焚毁凭据（/orders/[id] 读后即焚语义） */
export function discardOrderCredential(orderId: string): void {
  try {
    sessionStorage.removeItem(key(orderId));
  } catch {
    // ignore
  }
}
