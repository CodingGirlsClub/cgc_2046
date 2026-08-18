"use client";

/**
 * 收银模态框（桌面收费报名就地支付，不整页跳转）。
 *
 * 开框即结账：进框先查 MY_PENDING_ORDERS——有活单直接复用（凭据从
 * sessionStorage 交接，丢失则走「换渠道恢复」引导，复用订单页口径）；
 * 无活单按记忆渠道（cgc:last-payment-provider，缺省 wechat_native）
 * createOrder 即出码。渠道选择与二维码同屏，切换渠道走 replaceProvider
 * （R11：旧单作废新码即换，框内无感）。
 *
 * 轮询（R14）与倒计时（R6）复用 use-order-polling / lib/payment 纯函数，
 * 与 /orders/[id] 订单页同口径；paid → ✓ 报名已确认 + 1.5s 自动关框，
 * onPaid 先行触发调用方就地刷新报名态。
 *
 * 关框不撤单：订单留在 2h 有效窗内，「继续支付」重开本框即承接。
 * /orders/new 与 /orders/[id] 保持原样（手机端路径 + 兜底层）。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import QRCode from "qrcode";
import { client } from "@/lib/apollo-client";
import {
  CREATE_ORDER,
  MY_PENDING_ORDERS,
  ORDER_STATUS,
  REPLACE_PROVIDER,
  type Order,
  type PaymentProvider,
} from "@/lib/graphql/orders";
import {
  PROVIDER_LABEL,
  WEB_ENABLED_PROVIDERS,
  countdownText,
  dispatchCredential,
  formatAmount,
  type CredentialDispatch,
  type OrderPollStatus,
} from "@/lib/payment";
import { translatePaymentError } from "@/lib/payment-errors";
import {
  readOrderCredential,
  storeOrderCredential,
} from "@/lib/order-credential";
import {
  readLastPaymentProvider,
  rememberPaymentProvider,
} from "@/lib/last-payment-provider";
import { useOrderPolling } from "@/lib/use-order-polling";

const COUNTDOWN_TICK_MS = 500;
const PAID_AUTO_CLOSE_MS = 1_500;
const DEFAULT_PROVIDER: PaymentProvider = "wechat_native";

/** 模态框内流转的订单最小面（createOrder/replaceProvider 全量 Order 兼容） */
type CheckoutOrder = Pick<
  Order,
  "id" | "provider" | "status" | "amountCents" | "expireAt"
>;

type Phase = "checking" | "paying" | "error";

export interface PaymentCheckoutDialogProps {
  /** payment_pending 报名 id（承接其下单/复用活单） */
  enrollmentId: string;
  onClose: () => void;
  /** 支付成功回调：检测到 paid 即触发（先于 1.5s 自动关框），调用方就地刷新报名态 */
  onPaid: () => void;
  /** 订单未就绪时的金额占位（所选档位金额；订单就绪后以 order.amountCents 为准） */
  amountCents?: number | null;
  /** 所选档位名（头部展示；复访承接时可不传） */
  tierName?: string | null;
  /** 活动标题（头部展示） */
  title?: string | null;
}

const FOCUSABLE_SELECTOR =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export default function PaymentCheckoutDialog({
  enrollmentId,
  onClose,
  onPaid,
  amountCents: amountHintCents = null,
  tierName = null,
  title = null,
}: PaymentCheckoutDialogProps) {
  const [phase, setPhase] = useState<Phase>("checking");
  const [order, setOrder] = useState<CheckoutOrder | null>(null);
  const [credential, setCredential] = useState<unknown>(null);
  const [provider, setProvider] = useState<PaymentProvider | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [nowMs, setNowMs] = useState(() => Date.now());
  const [generatedQr, setGeneratedQr] = useState<string | null>(null);

  // 回调经 ref 隔离：paid 效果只依赖 paid 布尔，不随父级重渲重触发
  //（赋值收进 effect——React Compiler 禁止渲染期写 ref）
  const onPaidRef = useRef(onPaid);
  const onCloseRef = useRef(onClose);
  useEffect(() => {
    onPaidRef.current = onPaid;
    onCloseRef.current = onClose;
  });

  const dialogRef = useRef<HTMLDivElement>(null);
  const orderId = order?.id ?? null;

  // 开框聚焦对话框本体（Esc/Tab trap 的焦点锚点）
  useEffect(() => {
    dialogRef.current?.focus();
  }, []);

  // 状态轮询的拉取（R14；合并保 provider——ORDER_STATUS 不回该字段，整替会丢渠道选中态）。
  // 乱序守卫：闭包捕获请求时 orderId，响应回来时订单已被换渠道替换（prev.id 变了）
  // 则丢弃——迟到的旧单响应（换渠道后原单 cancelled）覆盖新单会误停轮询
  const fetchStatus = useCallback(async () => {
    if (!orderId) return;
    const { data } = await client.query({
      query: ORDER_STATUS,
      variables: { id: orderId },
      fetchPolicy: "network-only",
    });
    const fresh = data?.orderStatus;
    if (fresh) {
      setOrder((prev) =>
        prev && prev.id === orderId ? { ...prev, ...fresh } : prev,
      );
    }
  }, [orderId]);

  const status = (order?.status ?? "pending") as OrderPollStatus;
  const paid = status === "paid";
  // busy（下单/换渠道在飞）时暂停轮询：换渠道窗口内旧单正被作废，此刻拉旧单
  // 会拿到 cancelled 终态误停轮询
  const poll = useOrderPolling({
    enabled: phase === "paying" && orderId !== null && !busy,
    status,
    onTick: fetchStatus,
  });

  // 下单（无活单初始路径；也承接下单失败后的换渠道重试）
  const createOrder = useCallback(
    async (next: PaymentProvider) => {
      setBusy(true);
      setError(null);
      try {
        const { data } = await client.mutate({
          mutation: CREATE_ORDER,
          variables: { input: { enrollmentId, provider: next } },
        });
        const payload = data?.createOrder;
        if (payload?.result) {
          // 凭据落 sessionStorage（/orders/[id] 兜底路径可续），不落 URL
          storeOrderCredential(payload.result.id, payload.metadata?.credential);
          setOrder(payload.result);
          setCredential(payload.metadata?.credential ?? null);
          setProvider(next);
          rememberPaymentProvider(next);
          setPhase("paying");
        } else {
          setPhase("error");
          setError(
            translatePaymentError(
              payload?.errors[0]?.code,
              "下单失败，请重试",
            ),
          );
        }
      } catch (e) {
        setPhase("error");
        setError(
          translatePaymentError(
            e instanceof Error ? e.message : null,
            "下单失败，请重试",
          ),
        );
      } finally {
        setBusy(false);
      }
    },
    [enrollmentId],
  );

  // 开框初始化（一次）：复用活单 or 初始下单
  useEffect(() => {
    let cancelled = false;
    (async () => {
      let pending: CheckoutOrder | null = null;
      try {
        const { data } = await client.query({
          query: MY_PENDING_ORDERS,
          variables: { enrollmentId },
          fetchPolicy: "network-only",
        });
        pending = data?.myOrders?.results?.[0] ?? null;
      } catch {
        // 守卫查询失败不阻塞：落 createOrder 由其错误面兜底
        pending = null;
      }
      if (cancelled) return;
      if (pending) {
        // 复用活单：凭据读 sessionStorage 但不焚毁（本框可反复开关，且
        // /orders/[id] 兜底路径仍需；丢失 → credentialLost 引导换渠道恢复）
        setOrder(pending);
        setProvider(pending.provider as PaymentProvider);
        setCredential(readOrderCredential(pending.id));
        setPhase("paying");
        return;
      }
      await createOrder(readLastPaymentProvider() ?? DEFAULT_PROVIDER);
    })();
    return () => {
      cancelled = true;
    };
  }, [enrollmentId, createOrder]);

  // 换渠道（R11）：旧单作废新单新凭据，框内就地换码；轮询窗重置
  const switchProvider = useCallback(
    async (next: PaymentProvider) => {
      if (!order || busy || next === provider) return;
      setBusy(true);
      setError(null);
      try {
        const { data } = await client.mutate({
          mutation: REPLACE_PROVIDER,
          variables: { input: { orderId: order.id, provider: next } },
        });
        const payload = data?.replaceProvider;
        if (payload?.result) {
          storeOrderCredential(payload.result.id, payload.metadata?.credential);
          setOrder(payload.result);
          setCredential(payload.metadata?.credential ?? null);
          setProvider(next);
          rememberPaymentProvider(next);
          poll.reset();
        } else {
          setError(
            translatePaymentError(
              payload?.errors[0]?.code,
              "切换渠道失败，请重试",
            ),
          );
        }
      } catch (e) {
        setError(
          translatePaymentError(
            e instanceof Error ? e.message : null,
            "切换渠道失败，请重试",
          ),
        );
      } finally {
        setBusy(false);
      }
    },
    [order, busy, provider, poll],
  );

  // 支付成功：✓ 报名已确认 → 1.5s 自动关框（onPaid 先行，报名区就地刷新）
  useEffect(() => {
    if (!paid) return;
    onPaidRef.current();
    const timer = setTimeout(() => onCloseRef.current(), PAID_AUTO_CLOSE_MS);
    return () => clearTimeout(timer);
  }, [paid]);

  // 倒计时刷新（R6）
  useEffect(() => {
    const timer = setInterval(() => setNowMs(Date.now()), COUNTDOWN_TICK_MS);
    return () => clearInterval(timer);
  }, []);

  // 凭据分派（R13）+ 二维码渲染（qrcode MIT）
  const dispatch: CredentialDispatch = useMemo(
    () => dispatchCredential(credential),
    [credential],
  );

  useEffect(() => {
    if (dispatch.mode !== "qr") return;
    let cancelled = false;
    QRCode.toDataURL(dispatch.url, { width: 200, margin: 1 })
      .then((url) => {
        if (!cancelled) setGeneratedQr(url);
      })
      .catch(() => {
        if (!cancelled) setGeneratedQr(null);
      });
    return () => {
      cancelled = true;
    };
  }, [dispatch]);

  const qrDataUrl = dispatch.mode === "qr" ? generatedQr : null;
  const remain = countdownText(nowMs, order?.expireAt);
  const expired = remain === "已过期" && !paid;
  // 复用活单但凭据丢失（sessionStorage 焚毁/跨 tab 下单）：换渠道恢复引导
  // （订单页同款口径：非当前渠道按钮 primary 高亮）
  const credentialLost =
    dispatch.mode === "unsupported" &&
    credential === null &&
    status === "pending";
  const amountCents = order?.amountCents ?? amountHintCents;

  // Esc 关闭 + Tab focus trap（对话框内循环）
  function handleKeyDown(e: React.KeyboardEvent<HTMLDivElement>) {
    if (e.key === "Escape") {
      e.stopPropagation();
      onClose();
      return;
    }
    if (e.key !== "Tab") return;
    const el = dialogRef.current;
    if (!el) return;
    const focusables = Array.from(
      el.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR),
    );
    if (focusables.length === 0) return;
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    const active = document.activeElement;
    if (e.shiftKey && (active === first || active === el)) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && active === last) {
      e.preventDefault();
      first.focus();
    }
  }

  return (
    <div
      className="modal-overlay"
      data-testid="checkout-overlay"
      onClick={onClose}
      onKeyDown={handleKeyDown}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-label="扫码支付"
        tabIndex={-1}
        className="modal-content"
        data-testid="checkout-dialog"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <h2>扫码支付</h2>
            <p className="mt-1 text-[13px] leading-5 text-ink-3">
              {[title, tierName].filter(Boolean).join(" · ") || "报名订单"}
              {amountCents != null ? (
                <span className="ml-2 font-medium text-ink">
                  ¥{formatAmount(amountCents)}
                </span>
              ) : null}
            </p>
          </div>
          <div className="flex flex-none items-center gap-2">
            {order !== null && !paid ? (
              <span
                data-testid="checkout-countdown"
                className={`rounded-full border px-2.5 py-1 text-xs ${
                  expired
                    ? "border-line text-ink-3"
                    : "border-amber-400/40 text-amber-300"
                }`}
              >
                {remain}
              </span>
            ) : null}
            <button
              type="button"
              aria-label="关闭"
              data-testid="checkout-close"
              onClick={onClose}
              className="rounded-large border border-line px-2 py-1 text-sm text-ink-3 hover:border-line-strong hover:text-ink"
            >
              ✕
            </button>
          </div>
        </div>

        {paid ? (
          <div
            className="grid justify-items-center gap-2 py-8"
            data-testid="checkout-paid"
            role="status"
          >
            <span className="grid h-12 w-12 place-items-center rounded-full border border-line-strong text-lg text-ink">
              ✓
            </span>
            <p className="text-sm font-medium text-ink">支付完成，报名已确认</p>
            <p className="text-[13px] text-ink-3">即将自动关闭…</p>
          </div>
        ) : phase === "checking" ? (
          <div
            className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line"
            data-testid="checkout-loading"
          />
        ) : (
          <>
            {/* 渠道选择（签约单源派生；选中态禁点，busy 防重） */}
            <div>
              <span className="block text-[13px] text-ink-3">支付渠道</span>
              <div
                className="mt-2 grid grid-cols-2 gap-2"
                data-testid="checkout-providers"
              >
                {WEB_ENABLED_PROVIDERS.map((p) => {
                  const selected = p === provider;
                  return (
                    <button
                      key={p}
                      type="button"
                      data-testid={`checkout-provider-${p}`}
                      disabled={busy || selected || expired}
                      aria-pressed={selected}
                      onClick={() => {
                        if (order) void switchProvider(p);
                        else void createOrder(p);
                      }}
                      className={
                        selected
                          ? "flex items-center justify-center rounded-large border border-accent bg-soft-2 px-3 py-3 text-sm font-medium text-accent disabled:opacity-100"
                          : credentialLost
                            ? "join-button join-button--primary"
                            : "flex items-center justify-center rounded-large border border-line bg-card px-3 py-3 text-sm text-ink-2 hover:border-line-strong disabled:opacity-50"
                      }
                    >
                      {PROVIDER_LABEL[p]}
                    </button>
                  );
                })}
              </div>
            </div>

            {/* 凭据区（订单就绪且未过期才渲染） */}
            {order !== null && !expired ? (
              <div
                className="grid justify-items-center gap-2 rounded-large border border-line bg-soft-2 p-4"
                data-testid="checkout-credential"
              >
                {dispatch.mode === "qr" ? (
                  <>
                    {qrDataUrl ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img
                        src={qrDataUrl}
                        alt={
                          provider === "alipay_qr"
                            ? "支付宝支付二维码"
                            : "微信支付二维码"
                        }
                        width={200}
                        height={200}
                        data-testid="checkout-qr"
                        className="rounded-large border border-line bg-white p-2"
                      />
                    ) : (
                      <div className="grid h-[200px] w-[200px] place-items-center rounded-large border border-line bg-card text-xs text-ink-3">
                        二维码生成中…
                      </div>
                    )}
                    <p className="text-[13px] text-ink-3">
                      {provider === "alipay_qr"
                        ? "使用支付宝扫一扫完成支付"
                        : "使用微信扫码完成支付"}
                    </p>
                  </>
                ) : dispatch.mode === "redirect" ? (
                  <div className="grid gap-2 justify-items-center">
                    <a
                      href={dispatch.url}
                      target="_blank"
                      rel="noreferrer"
                      className="join-button join-button--primary"
                      data-testid="checkout-redirect"
                    >
                      前往支付宝支付
                    </a>
                    <p className="text-[13px] text-ink-3">
                      新窗口完成支付后回到本页，状态将自动确认。
                    </p>
                  </div>
                ) : (
                  <p
                    className="text-sm text-ink-3"
                    data-testid="checkout-credential-unsupported"
                  >
                    {credentialLost
                      ? "支付凭据已失效，请点击其他支付方式重新获取（无需重新报名）。"
                      : dispatch.reason}
                  </p>
                )}
              </div>
            ) : null}

            {/* 状态行：错误 > 过期 > 手动态 > 轮询中 */}
            {error ? (
              <p
                role="alert"
                className="text-[13px] text-red-300"
                data-testid="checkout-error"
              >
                {error}
              </p>
            ) : expired ? (
              <p
                className="text-[13px] text-ink-3"
                data-testid="checkout-expired-note"
              >
                订单超时未支付，名额已释放。关闭后可重新报名。
              </p>
            ) : poll.manual ? (
              <div className="grid gap-2" data-testid="checkout-manual">
                <p className="text-[13px] text-ink-3">
                  自动确认已暂停（30 秒）。完成支付后请刷新状态。
                </p>
                <button
                  type="button"
                  onClick={poll.reset}
                  className="justify-self-start rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line"
                >
                  刷新状态
                </button>
              </div>
            ) : order !== null ? (
              <p
                className="text-[13px] text-ink-3"
                data-testid="checkout-polling"
              >
                正在确认支付状态…（每 2 秒自动刷新）
              </p>
            ) : null}

            <p className="text-[12px] leading-5 text-ink-3">
              订单 2
              小时内有效，关闭本窗口不取消订单，可从「继续支付」重新进入。
            </p>
          </>
        )}
      </div>
    </div>
  );
}
