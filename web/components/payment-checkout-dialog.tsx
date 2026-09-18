"use client";

/**
 * 收银模态框（桌面收费报名就地支付，不整页跳转）。
 *
 * 开框即结账：进框先查 MY_PENDING_ORDERS——有活单直接复用（凭据从
 * sessionStorage 交接，丢失则走「换渠道恢复」引导，复用订单页口径）；
 * 无活单按记忆渠道（cgc:last-payment-provider，缺省 wechat_native）
 * createOrder 即出码。渠道选择与二维码同屏，切换渠道走 replaceProvider
 * （R11：旧单作废新码即换，框内无感）。
 * 押金口径判据（#580/#686/#748）：有活单 → 同意门与说明行金额只认**订单快照**
 * （orderKind / amountCents，下单时定，组织者事后改配置不漂移）；订单未建立的
 * 瞬间 → 押金事实由本框**自取 MY_ENROLLMENT**（#748 快照化：paymentMode 识别 +
 * depositAmountCents 披露，与 /orders/new、后端创单金额同源同值），调用方不再
 * 下传活动现价——弹框两调用方传现价的旧路径是「同意的金额 ≠ 扣款金额」的
 * 根因（#748 F-02 HIGH）。快照不可得（查询失败/金额脏）→「金额待定」（#675）。
 * orderKind 解析 fail-closed（parseOrderKind 未知值 → error 态，不猜方向）。
 *
 * 轮询（R14）与倒计时（R6）复用 use-order-polling / lib/payment 纯函数，
 * 与 /orders/[id] 订单页同口径；paid → ✓ 报名已确认 + 1.5s 自动关框，
 * onPaid 先行触发调用方就地刷新报名态。
 *
 * 关框不撤单：订单留在 2h 有效窗内，「继续支付」重开本框即承接。
 * /orders/new 与 /orders/[id] 保持原样（手机端路径 + 兜底层）。
 *
 * 押金同意门下沉（#727）：创单时随载荷带 `depositConsent`（押金收银才带 true）。
 * 若后端仍以 order_deposit_consent_required 拒单（本框押金识别缺失/过期，
 * fail-open 类），不落死 error 态——就地回到 consent 阶段补披露与勾选（自愈），
 * 用户勾选后重试创单；错误文案的权威来源始终是后端。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import { useQrDataUrl } from "@/lib/use-qr-data-url";
import {
  CREATE_ORDER,
  DEPOSIT_CONSENT_REQUIRED_CODE,
  DEPOSIT_CONSENT_MISSING_CODE,
  createOrderInput,
  MY_PENDING_ORDERS,
  ORDER_STATUS,
  REPLACE_PROVIDER,
  type Order,
  type PaymentProvider,
} from "@/lib/graphql/orders";
import {
  CREDENTIAL_REASON_LABEL,
  PROVIDER_LABEL,
  WEB_ENABLED_PROVIDERS,
  countdownText,
  dispatchCredential,
  formatAmount,
  formatAmountShort,
  parseOrderKind,
  positiveAmountOrNull,
  type CredentialDispatch,
  type OrderPollStatus,
} from "@/lib/payment";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import {
  readOrderCredential,
  storeOrderCredential,
} from "@/lib/order-credential";
import { storeOrderContext } from "@/lib/order-context";
import {
  readLastPaymentProvider,
  rememberPaymentProvider,
} from "@/lib/last-payment-provider";
import { useOrderPolling } from "@/lib/use-order-polling";
import OrderPaidDetails from "./order-paid-details";
import { MY_ENROLLMENT } from "@/lib/graphql/events";
import { useDialogA11y } from "./modal-a11y";

const COUNTDOWN_TICK_MS = 500;
const PAID_AUTO_CLOSE_MS = 1_500;
const DEFAULT_PROVIDER: PaymentProvider = "wechat_native";

/** 模态框内流转的订单最小面（createOrder/replaceProvider 全量 Order 兼容） */
type CheckoutOrder = Pick<
  Order,
  | "id"
  | "provider"
  | "status"
  | "amountCents"
  | "expireAt"
  | "outTradeNo"
  | "orderKind"
>;

// U1：押金单在钱动前停在「以到场为退还条件」确认态（consent）——门由订单
// 快照口径（或无单时刻的报名快照）判定（#580/#748），未确认前不产生任何
// 渠道单/凭据
type Phase = "consent" | "checking" | "paying" | "error";

/** 押金事实（MY_ENROLLMENT 随返，#748）：识别 + 披露金额与创单同源 */
type EnrollDeposit = {
  paymentMode: string | null;
  depositAmountCents: number | null;
};

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

/**
 * 收银上下文（调用方 state 形状 = 弹框 props 减去回调）。Required 刻意收紧：
 * 调用方组装载荷漏传任一键都是编译错，不给「漏传静默 fail-open」留缝（#686）。
 * 押金事实不在载荷里（#748 快照化）：弹框自取 MY_ENROLLMENT。
 */
export type PaymentCheckoutContext = Required<
  Omit<PaymentCheckoutDialogProps, "onClose" | "onPaid">
>;

export default function PaymentCheckoutDialog({
  enrollmentId,
  onClose,
  onPaid,
  amountCents: amountHintCents = null,
  tierName = null,
  title = null,
}: PaymentCheckoutDialogProps) {
  const translatePaymentError = usePaymentErrorTranslator();
  const t = useTranslations("checkout");
  // 押金不表态文案单源在 `offerings`（#675，与公开页/报名页同句）
  const tOfferings = useTranslations("offerings");
  const labelsT = useTranslations();
  // 开框统一 checking：并行查活单（订单快照口径 orderKind）与报名快照（押金
  // 事实 paymentMode/depositAmountCents，#748）再定 consent/paying
  // （#580）——押金门不再由调用方下传的活动实时配置预判
  const [phase, setPhase] = useState<Phase>("checking");
  // 押金确认勾选（本框生命周期内一次性；重开框重置）
  const [depositAck, setDepositAck] = useState(false);
  // 后端判定「这是押金单」（order_deposit_consent_required，#727 自愈）：本框
  // 押金识别缺失/过期时采纳，让重试创单带上同意标记（而非再次裸发）
  const [backendDepositRequired, setBackendDepositRequired] = useState(false);
  // 报名快照押金事实（#748 自取 MY_ENROLLMENT）：无活单时识别判据 +
  // 披露金额源；查询失败落 null → 按非押金场处理（既有「不阻塞下单」兜底，
  // 错误由 createOrder 翻译层承接 + #727 自愈回 consent）
  const [enrollDeposit, setEnrollDeposit] = useState<EnrollDeposit | null>(null);
  const [order, setOrder] = useState<CheckoutOrder | null>(null);
  const [credential, setCredential] = useState<unknown>(null);
  const [provider, setProvider] = useState<PaymentProvider | null>(null);
  // 同帧连点锁（#751）：setState 异步生效，快速双击两次 click 都带旧 state，
  // disabled 拦不住——ref 在第一次进入时即置位，第二次直接返回（防双创单）
  const busyRef = useRef(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [nowMs, setNowMs] = useState(() => Date.now());

  // 回调经 ref 隔离：paid 效果只依赖 paid 布尔，不随父级重渲重触发
  //（赋值收进 effect——React Compiler 禁止渲染期写 ref）
  const onPaidRef = useRef(onPaid);
  const onCloseRef = useRef(onClose);
  useEffect(() => {
    onPaidRef.current = onPaid;
    onCloseRef.current = onClose;
  });

  // 模态 a11y 机制（开框聚焦 + Esc 关 + Tab focus trap）单源在 ./modal-a11y
  const { dialogRef, handleKeyDown } = useDialogA11y(onClose);
  const orderId = order?.id ?? null;

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

  // 押金口径（#580/#686/#748）：订单就绪 → 只认订单快照 orderKind；未就绪
  // （无活单的 consent 预判路径）→ 报名快照 paymentMode（#748 自取
  // MY_ENROLLMENT，与后端创单金额同源；金额不参与识别——脏金额绝不让押金单
  // 掉进非押金分支连披露门都不出）；后端拒单 order_deposit_consent_required
  // 是第三来源（#727 自愈）：后端按 order_kind 判押金而本框识别缺失时，采纳
  // 后端判定——否则自愈路径会带着「非押金」的身份重试创单，形成死循环。
  // 创单门与渲染判据共用本表达式（单源）。
  const isDepositCheckout =
    order?.orderKind === "deposit" ||
    (order === null &&
      (enrollDeposit?.paymentMode === "deposit" || backendDepositRequired));

  // 下单（无活单初始路径；也承接下单失败后的换渠道重试）
  const createOrder = useCallback(
    async (next: PaymentProvider) => {
      // 押金单同意前置于创单（#727，与 /orders/new、小程序同构）：未勾选不发
      // 创单请求，回到 consent 阶段补披露（覆盖 error 态的渠道按钮残留路径）
      if (isDepositCheckout && !depositAck) {
        setPhase("consent");
        return;
      }
      if (busyRef.current) return;
      busyRef.current = true;
      setBusy(true);
      setError(null);
      try {
        const { data } = await client.mutate({
          mutation: CREATE_ORDER,
          variables: {
            input: createOrderInput(
              enrollmentId,
              next,
              isDepositCheckout ? depositAck : undefined,
            ),
          },
        });
        const payload = data?.createOrder;
        if (payload?.result) {
          const kind = parseOrderKind(payload.result.orderKind);
          if (kind === null) {
            // fail-closed（#580）：新单口径不可判——停支付面不出码，单留 pending
            // 可经换渠道重试 / 「继续支付」承接
            setPhase("error");
            setError(t("orderKindUnknown"));
            return;
          }
          // 口径漂移（#748 F-08）：以押金同意身份发起、落单却是非押金（勾选后
          // 创单前组织者关押金的时序窗口）。fail-safe：不出码——静默出示一笔
          // 用户没同意过的定价单不如显式中断；单留 pending，重试即按新口径
          // 幂等落单出码。
          if (isDepositCheckout && kind !== "deposit") {
            setPhase("error");
            setError(t("orderKindDrifted"));
            return;
          }
          // 凭据落 sessionStorage（/orders/[id] 兜底路径可续），不落 URL
          storeOrderCredential(payload.result.id, payload.metadata?.credential);
          // 活动名上下文同口径交接（订单页成功卡明细行；无 title 上下文跳过）
          storeOrderContext(payload.result.id, title);
          setOrder(payload.result);
          setCredential(payload.metadata?.credential ?? null);
          setProvider(next);
          rememberPaymentProvider(next);
          setPhase("paying");
        } else {
          const code = payload?.errors[0]?.code;
          setError(translatePaymentError(code, t("orderFailed")));
          // 自愈（#727）：后端判押金而本框押金识别缺失/过期（fail-open 类）→
          // 采纳后端判定 + 就地回 consent 补披露与勾选；用户勾选后重试创单即带
          // depositConsent: true，不落死 error 态。保留用户已选渠道（F-06）：
          // consent 确认按钮沿 next 重发，不回落记忆渠道
          if (code === DEPOSIT_CONSENT_REQUIRED_CODE) {
            setProvider(next);
            setBackendDepositRequired(true);
            setPhase("consent");
          } else {
            setPhase("error");
          }
        }
      } catch (e) {
        setPhase("error");
        setError(
          translatePaymentError(
            e instanceof Error ? e.message : null,
            t("orderFailed"),
          ),
        );
      } finally {
        busyRef.current = false;
        setBusy(false);
      }
    },
    [
      enrollmentId,
      title,
      t,
      translatePaymentError,
      isDepositCheckout,
      depositAck,
    ],
  );

  // 开框初始化：并行查活单（订单快照口径）与报名快照（押金事实，#748）
  // → 复用活单 or 初始下单。押金口径不可判（orderKind 缺失/未知）→ fail-closed
  // 停支付面。
  // 守卫在 cleanup 中解锁（React StrictMode dev 双跑：mount→unmount→remount
  // 会取消首次异步；守卫若不解锁，remount 一眼看到「已初始化」直接跳过，
  // 弹框永久停在 checking）
  const initInFlightRef = useRef(false);
  useEffect(() => {
    if (phase !== "checking" || initInFlightRef.current) return;
    initInFlightRef.current = true;
    let cancelled = false;
    (async () => {
      // 两查并行；押金事实查询失败不阻塞（enrollDeposit = null 按非押金场
      // 处理，错误由 createOrder 翻译层兜底）——同 /orders/new 守卫口径
      const [pendingResult, enrollResult] = await Promise.allSettled([
        client.query({
          query: MY_PENDING_ORDERS,
          variables: { enrollmentId },
          fetchPolicy: "network-only",
        }),
        client.query({
          query: MY_ENROLLMENT,
          variables: { id: enrollmentId },
          fetchPolicy: "network-only",
        }),
      ]);
      if (cancelled) return;

      // fulfilled 的 value 兜底 `?.`：测试 mock 漏实现时 allSettled 会把
      // undefined 当 fulfilled 值传入，不应伪装成组件崩溃（CI #757 教训）
      const pending: CheckoutOrder | null =
        pendingResult.status === "fulfilled"
          ? (pendingResult.value?.data?.myOrders?.results?.[0] ?? null)
          : null;
      const enrollment =
        enrollResult.status === "fulfilled"
          ? (enrollResult.value?.data?.myEnrollments?.results?.[0] ?? null)
          : null;
      setEnrollDeposit({
        paymentMode: enrollment?.paymentMode ?? null,
        depositAmountCents: enrollment?.depositAmountCents ?? null,
      });

      if (pending) {
        const kind = parseOrderKind(pending.orderKind);
        if (kind === null) {
          setPhase("error");
          setError(t("orderKindUnknown"));
          return;
        }
        // 复用活单：凭据读 sessionStorage 但不焚毁（本框可反复开关，且
        // /orders/[id] 兜底路径仍需；丢失 → credentialLost 引导换渠道恢复）
        storeOrderContext(pending.id, title);
        setOrder(pending);
        setProvider(pending.provider as PaymentProvider);
        setCredential(readOrderCredential(pending.id));
        // 押金门只认订单快照口径：组织者事后关押金，押金活单仍过披露门
        setPhase(kind === "deposit" ? "consent" : "paying");
        return;
      }
      if (enrollment?.paymentMode === "deposit") {
        // 无活单 + 押金场：先停确认态（U1），确认后才创单——此刻尚无订单，
        // 披露金额 = 报名快照（#748），与创单实付同源。识别按 paymentMode
        // 存在性（#686）：金额缺失不漏门（金额只用于表态）
        setPhase("consent");
        return;
      }
      await createOrder(readLastPaymentProvider() ?? DEFAULT_PROVIDER);
    })();
    return () => {
      cancelled = true;
      initInFlightRef.current = false;
    };
  }, [phase, enrollmentId, title, createOrder, t]);

  // 换渠道（R11）：旧单作废新单新凭据，框内就地换码；轮询窗重置
  const switchProvider = useCallback(
    async (next: PaymentProvider) => {
      if (!order || busyRef.current || next === provider) return;
      busyRef.current = true;
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
          // 换渠道产生新单：活动名上下文按新单 id 重写一份
          storeOrderContext(payload.result.id, title);
          setOrder(payload.result);
          setCredential(payload.metadata?.credential ?? null);
          setProvider(next);
          rememberPaymentProvider(next);
          poll.reset();
        } else {
          const code = payload?.errors[0]?.code;
          // #750/F-05 自愈：存量押金单无同意留痕被拒 → 带同意标记重新创单
          // （createOrder 幂等废旧单、按当前权威金额落新单并补留痕），框内
          if (code === DEPOSIT_CONSENT_MISSING_CODE && depositAck) {
            // createOrder 内部自持 busyRef 锁：先释放本函数持有的锁
            busyRef.current = false;
            setBusy(false);
            await createOrder(next);
            return;
          }
          setError(translatePaymentError(code, t("switchFailed")));
        }
      } catch (e) {
        setError(
          translatePaymentError(
            e instanceof Error ? e.message : null,
            t("switchFailed"),
          ),
        );
      } finally {
        busyRef.current = false;
        setBusy(false);
      }
    },
    [order, provider, poll, title, t, translatePaymentError, depositAck, createOrder],
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

  const qrDataUrl = useQrDataUrl(dispatch.mode === "qr" ? dispatch.url : null, 200);
  const remain = countdownText(nowMs, order?.expireAt, t("countdownExpired"));
  const expired = remain === t("countdownExpired") && !paid;
  // 复用活单但凭据丢失（sessionStorage 焚毁/跨 tab 下单）：换渠道恢复引导
  // （订单页同款口径：非当前渠道按钮 primary 高亮）
  const credentialLost =
    dispatch.mode === "unsupported" &&
    credential === null &&
    status === "pending";
  const amountCents = order?.amountCents ?? amountHintCents;
  // 说明行金额同源：订单快照优先、报名快照兜底（#748：与创单实付同源），
  // 且表态过守卫（#675）：脏金额（缺失/0/负/非整数分）→ null → 说明行
  // 「押金（金额待定）」，框头金额同步不显示（既有 null 分支），绝不出现
  // 「¥0.00」。识别不读金额（#686/#748：paymentMode/订单口径/后端判定定门），
  // 脏金额只影响表态不影响门。
  const depositNoteCents = positiveAmountOrNull(
    order?.amountCents ?? enrollDeposit?.depositAmountCents,
  );
  const headerAmountCents = positiveAmountOrNull(amountCents);

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
        aria-label={t("dialogAria")}
        tabIndex={-1}
        className="modal-content"
        data-testid="checkout-dialog"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <h2>{t("title")}</h2>
            <p className="mt-1 text-[13px] leading-5 text-ink-3">
              {[title, tierName].filter(Boolean).join(" · ") || t("orderFallback")}
              {headerAmountCents !== null ? (
                <span className="ml-2 font-medium text-ink">
                  ¥{formatAmount(headerAmountCents)}
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
              aria-label={t("closeAria")}
              data-testid="checkout-close"
              onClick={onClose}
              className="rounded-large border border-line px-2 py-1 text-sm text-ink-3 hover:border-line-strong hover:text-ink"
            >
              ✕
            </button>
          </div>
        </div>

        {isDepositCheckout ? (
          // R10/KTD10：押金单在收银框内明示押金口径与未到场不退（报名流程内披露）；
          // 金额绑订单快照（#580）：组织者改押金额后，在途单仍按扣款额披露。
          // #727：识别含后端判定（backendDepositRequired）——自愈路径的 consent
          // 阶段必有披露，门不退化成「无披露的勾选」。
          <p
            className="rounded-large border border-line bg-soft-2 px-3 py-2 text-[13px] leading-5 text-ink-2"
            data-testid="checkout-deposit-note"
          >
            {depositNoteCents === null
              ? tOfferings("paymentSlotDepositUnknown")
              : t("depositLine", {
                  amount: formatAmountShort(depositNoteCents),
                })}
            <span className="ml-2 text-ink-3">{t("depositForfeit")}</span>
          </p>
        ) : amountHintCents != null ? (
          // #543：定价场收银框明示退款规则（钱动前的报名流程内披露）
          <p
            className="rounded-large border border-line bg-soft-2 px-3 py-2 text-[13px] leading-5 text-ink-2"
            data-testid="checkout-pricing-note"
          >
            {t("pricingRefundNote")}
          </p>
        ) : null}

        {phase === "consent" ? (
          // U1：押金以到场为退还条件——付款前的显式确认（勾选后才能下单）
          <div
            className="grid gap-3 py-2"
            data-testid="checkout-deposit-consent"
          >
            <label className="flex items-start gap-2 text-[13px] leading-5 text-ink-2">
              <input
                type="checkbox"
                checked={depositAck}
                onChange={(e) => setDepositAck(e.target.checked)}
                data-testid="checkout-deposit-consent-checkbox"
                className="mt-0.5 h-4 w-4 accent-[var(--accent)]"
              />
              <span>{t("depositAckLabel")}</span>
            </label>
            {/* F-06：自愈回 consent 时不吞错误文案——错误权威来自后端拒单，
                折叠掉用户就不知道为何要重新确认 */}
            {error ? (
              <p
                role="alert"
                className="text-[13px] text-red-300"
                data-testid="checkout-consent-error"
              >
                {error}
              </p>
            ) : null}
            <button
              type="button"
              disabled={!depositAck || busy}
              onClick={() => {
                // 复用活单路径：单已就绪（含凭据），确认即进支付；无单路径：
                // 确认后才创单（U1：未确认前不产生任何订单/凭据）。
                // F-06：自愈前用户点过渠道（provider 已记住），沿它重发，
                // 不回落记忆渠道；busy 同帧锁在 createOrder 内部（#751）
                if (order !== null) setPhase("paying");
                else
                  void createOrder(
                    provider ?? readLastPaymentProvider() ?? DEFAULT_PROVIDER,
                  );
              }}
              data-testid="checkout-deposit-consent-button"
              className="join-button join-button--primary disabled:opacity-50"
            >
              {t("depositAckButton")}
            </button>
          </div>
        ) : paid ? (
          <div
            className="grid justify-items-center gap-2 py-8"
            data-testid="checkout-paid"
            role="status"
          >
            <span className="grid h-12 w-12 place-items-center rounded-full border border-line-strong text-lg text-ink">
              ✓
            </span>
            <p className="text-sm font-medium text-ink">{t("paidTitle")}</p>
            <OrderPaidDetails
              eventTitle={title}
              tierName={tierName}
              outTradeNo={order?.outTradeNo ?? null}
            />
            <p className="text-[13px] text-ink-3">{t("autoClose")}</p>
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
              <span className="block text-[13px] text-ink-3">{t("providerField")}</span>
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
                      {labelsT(PROVIDER_LABEL[p])}
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
                            ? t("alipayQrAlt")
                            : t("wechatQrAlt")
                        }
                        width={200}
                        height={200}
                        data-testid="checkout-qr"
                        className="rounded-large border border-line bg-white p-2"
                      />
                    ) : (
                      <div className="grid h-[200px] w-[200px] place-items-center rounded-large border border-line bg-card text-xs text-ink-3">
                        {t("qrGenerating")}
                      </div>
                    )}
                    <p className="text-[13px] text-ink-3">
                      {provider === "alipay_qr"
                        ? t("scanAlipay")
                        : t("scanWechat")}
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
                      {t("goAlipay")}
                    </a>
                    <p className="text-[13px] text-ink-3">
                      {t("newWindowNote")}
                    </p>
                  </div>
                ) : (
                  <p
                    className="text-sm text-ink-3"
                    data-testid="checkout-credential-unsupported"
                  >
                    {credentialLost
                      ? t("credentialLost")
                      : labelsT(CREDENTIAL_REASON_LABEL[dispatch.reason])}
                  </p>
                )}
              </div>
            ) : null}

            {/* 状态行：错误 > 过期 > 轮询中（降频续轮到终态，无手动态） */}
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
                {t("expiredNote")}
              </p>
            ) : order !== null ? (
              <p
                className="text-[13px] text-ink-3"
                data-testid="checkout-polling"
              >
                {t("checkingPayment")}
              </p>
            ) : null}

            <p className="text-[12px] leading-5 text-ink-3">
              {t("orderValidHint")}
            </p>
          </>
        )}
      </div>
    </div>
  );
}
