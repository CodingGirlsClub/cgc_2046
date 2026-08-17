/**
 * 上次支付渠道记忆（收银模态框首次打开的默认渠道）。
 *
 * localStorage key `cgc:last-payment-provider`（同 use-last-workspace 的
 * `cgc:` 前缀惯例）。只在 WEB_ENABLED_PROVIDERS 签约集内记忆——未签约值
 * （历史残留/手工篡改）静默忽略，回退 wechat_native。
 */

import { WEB_ENABLED_PROVIDERS } from "./payment";
import type { PaymentProvider } from "./graphql/orders";

const STORAGE_KEY = "cgc:last-payment-provider";

export function readLastPaymentProvider(): PaymentProvider | null {
  let raw: string | null = null;
  try {
    raw = window.localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
  return WEB_ENABLED_PROVIDERS.includes(raw as PaymentProvider)
    ? (raw as PaymentProvider)
    : null;
}

export function rememberPaymentProvider(provider: PaymentProvider): void {
  try {
    window.localStorage.setItem(STORAGE_KEY, provider);
  } catch {
    // ignore private-mode write errors
  }
}
