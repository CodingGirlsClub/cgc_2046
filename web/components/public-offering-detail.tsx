"use client";

/**
 * E-5 #50 公开宿主页 /events/[id] 与 /courses/[id]（游客可看详情，报名需登录）。
 *
 * - 详情：匿名读（open + public）；workspace 活动 / 非 open → 404 语义
 *   （读策略过滤 → get 返回 null）；
 * - 公开主题壳层：与目录共用品牌导航，不进入工作台导航；
 * - 信息密度（R9）：描述/开始/结束/截止时间/venue（仅 event）/报名政策/
 *   定价档位静态信息块（匿名可见；登录后 radio 选档器沿用为选择控件）；
 * - 行内状态标签 = 后端派生报名 badge（KTD1）；满员（AE1）不呈现报名动作；
 *   报名失败后重拉详情让 badge 重派生；
 * - 报名表单（J-Visitor → J-Learner）：
 *   - 未登录：引导 /login（登录后回到本页）；
 *   - open：直接提交 → confirmed；
 *   - request：提交 → 「申请审批中」中间态；
 *   - invite_only：邀请码输入（可空则后端报 invite_code_required）。
 */

import { Link } from "@/i18n/navigation";
import { useParams, useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { useAuthed } from "@/lib/use-authed";
import {
  fetchPublicOffering,
  formatVenue,
  parseSponsorshipTiers,
  parseVenue,
  submitEnrollment,
} from "@/lib/public-offerings";
import SponsorshipIntentForm from "@/components/sponsorship-intent-form";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import {
  ENROLLMENT_POLICY_LABEL,
  OFFERING_LABEL,
} from "@/lib/graphql/events";
import EnrollmentBadgeTag from "@/components/enrollment-badge-tag";
import CourseMapSection from "@/components/learning/course-map-section";
import { formatAmount, parsePriceTiers } from "@/lib/payment";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import { fetchMyEnrollment, formatDeadline } from "@/lib/events";
import PaymentCheckoutDialog from "@/components/payment-checkout-dialog";
import PublicCatalogShell from "@/components/public-catalog-shell";

interface DetailState {
  id: string;
  row: PublicOfferingItem | null;
  error: string | null;
}

export default function PublicOfferingDetailPage({
  kind,
}: {
  kind: OfferingKind;
}) {
  const params = useParams<{ slug: string }>();
  const slug = params?.slug ?? "";
  const router = useRouter();
  const { authed, userId } = useAuthed();
  const translatePaymentError = usePaymentErrorTranslator();
  const t = useTranslations("offeringDetail");
  const navT = useTranslations("landing.nav");
  const tCommon = useTranslations("common");
  const labelsT = useTranslations();
  const locale = useLocale();

  const [state, setState] = useState<DetailState>({
    id: "",
    row: null,
    error: null,
  });
  // 重试 nonce：load error 态点击重试 → 复位 + 触发 effect 重新拉取
  const [nonce, setNonce] = useState(0);
  const [inviteCode, setInviteCode] = useState("");
  // 判别式提交阶段（X3/B2 竞态闭环）四态：idle 可提交；submitting =
  // mutation 在途；reconciling = 失败后重拉详情在途；reconcile_failed =
  // 重拉失败稳态（resync 可点，在途时 disabled）。busy 贯穿非 idle 全程。
  const [submitPhase, setSubmitPhase] = useState<
    "idle" | "submitting" | "reconciling" | "reconcile_failed"
  >("idle");
  const busy = submitPhase !== "idle" && submitPhase !== "reconcile_failed";
  // generation 守卫（B2 迟到响应）：只有最新 reconcile 请求可回写状态。
  // 超时 loser 迟到 resolve 时 gen 已过期 → 丢弃，不覆盖较新的 full。
  const reconcileGenRef = useRef(0);
  const [tierId, setTierId] = useState<string | null>(null);
  const [submitState, setSubmitState] = useState<{
    kind: "idle" | "confirmed" | "pending" | "payment_pending" | "error";
    message: string | null;
    /** payment_pending 态的去支付入口目标（R5 报名 id） */
    enrollmentId: string | null;
  }>({ kind: "idle", message: null, enrollmentId: null });
  // 收银模态框（批①桌面）：payment_pending 报名的就地支付上下文；null = 关闭
  const [checkout, setCheckout] = useState<{
    enrollmentId: string;
    amountCents: number | null;
    tierName: string | null;
    title: string;
  } | null>(null);
  // 支付接续：登录态下查已有活跃报名（公开页报名需登录），分叉渲染——
  // payment_pending → 待支付卡；confirmed/pending → 已报名；无 → 报名表单。
  const [myEnroll, setMyEnroll] = useState<{
    id: string;
    status: string;
  } | null>(null);
  // 已完成的报名查询对应的 offering id（派生 enrollChecked，避免 effect 内
  // 同步 setState——eslint react-hooks/set-state-in-effect）
  const [enrollForId, setEnrollForId] = useState<string | null>(null);

  useEffect(() => {
    if (!slug) return;
    let cancelled = false;

    fetchPublicOffering(slug, kind)
      .then((row) => {
        if (!cancelled) setState({ id: slug, row, error: null });
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setState({
            id: slug,
            row: null,
            error: e instanceof Error ? e.message : t("loadFailed"),
          });
        }
      });

    return () => {
      cancelled = true;
    };
  }, [slug, kind, nonce, t]);

  const stale = state.id !== slug;
  const offering = stale ? null : state.row;
  const loadError = stale ? null : state.error;
  const enrollChecked = offering !== null && enrollForId === offering.id;
  const label = OFFERING_LABEL[kind];
  const listHref = kind === "event" ? "/events" : "/courses";
  const listLabel = navT(kind === "event" ? "events" : "courses");
  // 满员或报名截止：详情不再呈现可报名动作（已有报名的状态卡除外）。
  const enrollmentUnavailable =
    offering?.enrollmentBadge === "closed"
      ? { hint: t("closedHint"), testId: "enrollment-closed" }
      : offering?.enrollmentBadge === "full"
        ? { hint: t("fullHint"), testId: "enrollment-full" }
        : null;
  const enrollmentUnavailableNotice = enrollmentUnavailable ? (
    <div
      className="public-detail__unavailable"
      data-testid={enrollmentUnavailable.testId}
    >
      <p>{enrollmentUnavailable.hint}</p>
      <Link href={listHref} className="public-detail__browse">
        {t("browseOther", { label: listLabel })}
      </Link>
    </div>
  ) : null;

  // load error 态重试：复位回 skeleton 并重新拉取
  function retry() {
    setState({ id: "", row: null, error: null });
    setNonce((n) => n + 1);
  }
  // 报名失败后重拉详情：badge 由后端重派生（如提交瞬间满员 → 「已满」）。
  // gen 守卫（B2）：每次 reconcile 递增 generation，回写前校验自己仍是
  // 最新请求——超时 loser 迟到 resolve 时 gen 已过期，丢弃回写，不会把
  // 较新的 full 覆盖回旧 enrolling。成功路径同时清理失效档位选择（B3）。
  const refetchOfferingGen = useCallback(
    async (gen: number): Promise<boolean> => {
      if (!slug) return false;
      try {
        const row = await fetchPublicOffering(slug, kind);
        if (reconcileGenRef.current !== gen) return false;
        if (!row) return false;
        setState({ id: slug, row, error: null });
        const tiers = parsePriceTiers(row.availablePriceTiers);
        setTierId((current) =>
          current && tiers.some((tier) => tier.id === current) ? current : null,
        );
        return true;
      } catch {
        // 刷新失败保持现态；由调用方决定收敛路径（resync / 手动刷新页面）
        return false;
      }
    },
    [slug, kind],
  );

  // 有界等待 + 单飞（B2）：10s 超时按失败收敛；in-flight 守卫防重复请求
  // （失败态 resync 可点，但同一时刻只有一份 reconcile 在途）。
  const RECONCILE_TIMEOUT_MS = 10_000;
  const reconcilingRef = useRef(false);
  const reconcile = useCallback(async (): Promise<boolean> => {
    if (reconcilingRef.current) return false;
    reconcilingRef.current = true;
    const gen = ++reconcileGenRef.current;
    let timer: number | undefined;
    const bounded = new Promise<boolean>((resolve) => {
      timer = window.setTimeout(() => resolve(false), RECONCILE_TIMEOUT_MS);
    });
    const ok = await Promise.race([refetchOfferingGen(gen), bounded]);
    window.clearTimeout(timer);
    reconcilingRef.current = false;
    return ok;
  }, [refetchOfferingGen]);

  // 我的活跃报名（登录后才查；offering.id 就绪后发起）。失败按「未报名」
  // 处理（入口照常显示，不误报已报名）。
  useEffect(() => {
    if (!authed || !userId || !offering?.id) return;
    let cancelled = false;

    fetchMyEnrollment(offering.id, kind, userId)
      .then((enrollment) => {
        if (cancelled) return;
        setMyEnroll(enrollment);
        setEnrollForId(offering.id);
      })
      .catch(() => {
        if (cancelled) return;
        setMyEnroll(null);
        setEnrollForId(offering.id);
      });

    return () => {
      cancelled = true;
    };
  }, [authed, userId, offering?.id, kind]);

  // E-3 #48 赞助入口（仅 event；enabled + tiers 已配才显示，对齐 E-5 readiness ②）
  const sponsorshipTiers = offering
    ? parseSponsorshipTiers(offering.sponsorshipTiers)
    : [];
  const sponsorshipOpen =
    kind === "event" &&
    offering !== null &&
    offering.sponsorshipEnabled === true &&
    sponsorshipTiers.length > 0;

  // 收费目标：可售档位（R2 后端 availablePriceTiers 已过滤过期档，公开报名面
  // 只展示未过期档）与所选档（R5 报名须选档，e2e #3）
  const priceTiers = parsePriceTiers(offering?.availablePriceTiers);
  const paidTier = priceTiers.find((t) => t.id === tierId) ?? null;

  // 支付成功后就地刷新报名态（模态框 onPaid → payment_pending → confirmed）。
  // offeringId 先行解构（可选链入 dep 会让 React Compiler 无法保持手工 memoization）
  const offeringId = offering?.id ?? null;
  const refetchEnrollment = useCallback(async () => {
    if (!offeringId || !userId) return;
    try {
      const enrollment = await fetchMyEnrollment(offeringId, kind, userId);
      setMyEnroll(enrollment);
    } catch {
      // 刷新失败保持现态；手动刷新页面仍可恢复
    }
  }, [offeringId, kind, userId]);

  // 开收银模态框：收费目标带所选档上下文（金额/档名/标题），复访承接可不带
  function openCheckoutFor(enrollmentId: string) {
    setCheckout({
      enrollmentId,
      amountCents: paidTier?.amountCents ?? null,
      tierName: paidTier?.name ?? null,
      title: offering?.title ?? "",
    });
  }
  async function submit() {
    if (!offering || !authed || !userId) return;
    // 收费目标必须选档（R5）：当前有效 paidTier（B3）——tierId 字符串可能
    // 已因 refetch 后档位下架而失效，只认仍在可售集合中的选择。
    if (offering.pricingEnabled && !paidTier) {
      setSubmitState({
        kind: "error",
        message: tierId ? t("submitFailed") : t("pickTierFirst"),
        enrollmentId: null,
      });
      return;
    }
    setSubmitPhase("submitting");
    setSubmitState({ kind: "idle", message: null, enrollmentId: null });
    let reconcileOk = true;
    try {
      const res = await submitEnrollment({
        eventId: kind === "event" ? offering.id : undefined,
        courseId: kind === "course" ? offering.id : undefined,
        userId,
        inviteCode: inviteCode === "" ? null : inviteCode,
        tierId,
      });
      if (res.result) {
        const status = res.result.status;
        if (status === "payment_pending") {
          setSubmitState({
            kind: "payment_pending",
            message: t("slotReservedMsg"),
            enrollmentId: res.result.id,
          });
          // 桌面：报名占位成功即弹收银模态框（不整页跳转）
          openCheckoutFor(res.result.id);
        } else if (status === "pending") {
          setSubmitState({
            kind: "pending",
            message: t("pendingMsg"),
            enrollmentId: null,
          });
        } else {
          setSubmitState({
            kind: "confirmed",
            message: t("enrolledMsg"),
            enrollmentId: null,
          });
          router.refresh();
        }
      } else {
        // :tier_id_required / :tier_not_available / unique 冲突等 AshGraphql
        // 错误经翻译层映射为可读文案；未知错误走兜底，不透传 GraphQL 原文。
        // X3：失败后进入 reconciling（有界重拉）——落定前提交保持锁定。
        setSubmitState({
          kind: "error",
          message: translatePaymentError(res.errors[0]?.code, t("submitFailed")),
          enrollmentId: null,
        });
        setSubmitPhase("reconciling");
        reconcileOk = await reconcile();
      }
    } catch (e: unknown) {
      setSubmitState({
        kind: "error",
        message: translatePaymentError(
          e instanceof Error ? e.message : null,
          t("submitFailed"),
        ),
        enrollmentId: null,
      });
      setSubmitPhase("reconciling");
      reconcileOk = await reconcile();
    } finally {
      // reconcile 成功（badge/档位已重派生）→ 回 idle；失败/超时 →
      // reconcile_failed 稳态：resync 按钮可点（B2 单飞防重复请求）。
      setSubmitPhase(reconcileOk ? "idle" : "reconcile_failed");
    }
  }

  // reconcile_failed 稳态的重新同步出口（B2）：进入 reconciling（按钮
  // disabled），成功回 idle，失败回 reconcile_failed。单飞由 reconcile
  // 内 in-flight 守卫兜底。
  async function resync() {
    setSubmitPhase("reconciling");
    const ok = await reconcile();
    setSubmitPhase(ok ? "idle" : "reconcile_failed");
  }

  return (
    <PublicCatalogShell activeKind={kind} mainClassName="public-detail-main">
      <div className="public-catalog-container">
        <Link href={listHref} className="public-detail-back">
          <span aria-hidden="true">←</span>
          {t("backToList", { label: listLabel })}
        </Link>

        {loadError ? (
          <div className="public-catalog-state public-detail-state" role="alert">
            <p>
              {t("loadFailed")}：{loadError}
            </p>
            <button
              type="button"
              onClick={retry}
              className="public-catalog-retry"
            >
              {tCommon("retry")}
            </button>
          </div>
        ) : stale ? (
          <div className="public-detail-skeletons" aria-hidden="true">
            <div className="public-detail-skeleton public-detail-skeleton--hero" />
            <div className="public-detail-skeleton" />
            <div className="public-detail-skeleton" />
          </div>
        ) : offering === null ? (
          <section className="public-catalog-state public-detail-state">
            <h1>{t("notAccessibleTitle", { label: labelsT(label) })}</h1>
            <p>{t("notAccessibleDesc")}</p>
          </section>
        ) : (
          <article className="public-detail">
            <header className="public-detail__hero">
              <EnrollmentBadgeTag badge={offering.enrollmentBadge} />
              <h1>{offering.title}</h1>
            </header>

            <dl className="public-detail__facts">
              <div>
                <dt>{t("startsTitle")}</dt>
                <dd>
                  {formatDeadline(
                    offering.startsAt ?? null,
                    tCommon("timeTbd"),
                    locale,
                  )}
                </dd>
              </div>
              <div>
                <dt>{t("endsTitle")}</dt>
                <dd>
                  {formatDeadline(
                    offering.endsAt ?? null,
                    tCommon("timeTbd"),
                    locale,
                  )}
                </dd>
              </div>
              <div>
                <dt>{t("deadlineTitle")}</dt>
                <dd>
                  {formatDeadline(
                    offering.registrationDeadline,
                    tCommon("noDeadline"),
                    locale,
                  )}
                </dd>
              </div>
              {kind === "event" ? (
                <div>
                  <dt>{t("venueTitle")}</dt>
                  <dd>
                    {formatVenue(parseVenue(offering.venue)) ??
                      tCommon("venueTbd")}
                  </dd>
                </div>
              ) : null}
              <div>
                <dt>{t("policyTitle")}</dt>
                <dd>
                  {labelsT(
                    ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy],
                  )}
                </dd>
              </div>
            </dl>

            <aside
              className="public-detail__rail"
              aria-labelledby="public-detail-registration-title"
            >
              <h2 id="public-detail-registration-title">
                {t("registrationTitle")}
              </h2>

              {/* 定价档位静态信息块（R9，匿名可见）；登录后 radio 选档器沿用现状作选择控件 */}
              {offering.pricingEnabled && priceTiers.length > 0 ? (
                <div
                  className="public-detail__pricing"
                  data-testid="price-tier-info"
                >
                  <h3>{t("pricingTitle")}</h3>
                  <ul>
                    {priceTiers.map((tier) => (
                      <li key={tier.id}>
                        <span>{tier.name}</span>
                        <strong>¥{formatAmount(tier.amountCents)}</strong>
                      </li>
                    ))}
                  </ul>
                </div>
              ) : null}

              <div className="public-detail__enrollment">
                {!authed ? (
                  enrollmentUnavailable ? (
                    enrollmentUnavailableNotice
                  ) : (
                    <div className="text-sm">
                      <Link
                        href={`/login?next=${encodeURIComponent(`${listHref}/${offering.slug}`)}`}
                        className="join-button join-button--primary inline-block"
                      >
                        {t("loginToEnroll")}
                      </Link>
                      <p className="mt-2 text-[13px] text-ink-3">
                        {t("signInToEnrollHint")}
                      </p>
                    </div>
                  )
                ) : submitState.kind === "confirmed" ||
                  submitState.kind === "pending" ||
                  submitState.kind === "payment_pending" ? (
                  <div className="text-sm" role="status">
                    <p className="font-medium">
                      {submitState.kind === "confirmed"
                        ? t("enrolledConfirm")
                        : submitState.kind === "payment_pending"
                          ? t("pendingPay")
                          : t("submitted")}
                    </p>
                    <p className="mt-1 text-[13px] text-ink-3">
                      {submitState.message}
                    </p>
                    {submitState.kind === "payment_pending" &&
                    submitState.enrollmentId ? (
                      <button
                        type="button"
                        onClick={() =>
                          openCheckoutFor(submitState.enrollmentId!)
                        }
                        className="join-button join-button--primary mt-3 inline-block"
                        data-testid="public-enrollment-continue-pay"
                      >
                        {t("continuePay")}
                      </button>
                    ) : (
                      <Link
                        href="/participations"
                        className="mt-3 inline-block text-[13px] text-accent hover:underline"
                      >
                        {t("viewInParticipations")}
                      </Link>
                    )}
                  </div>
                ) : myEnroll?.status === "payment_pending" ? (
                  <div
                    className="text-sm"
                    role="status"
                    data-testid="public-enrollment-pending-card"
                  >
                    <p className="font-medium">{t("slotReserved")}</p>
                    <button
                      type="button"
                      onClick={() => openCheckoutFor(myEnroll!.id)}
                      className="join-button join-button--primary mt-3 inline-block"
                      data-testid="public-enrollment-pending-pay"
                    >
                      {t("continuePay")}
                    </button>
                  </div>
                ) : myEnroll?.status === "pending" ? (
                  <div className="text-sm" role="status">
                    <p className="font-medium">
                      {t("pendingApproval", { label: labelsT(label) })}
                    </p>
                    <Link
                      href="/participations"
                      className="mt-3 inline-block text-[13px] text-accent hover:underline"
                    >
                      {t("viewInParticipations")}
                    </Link>
                  </div>
                ) : myEnroll ? (
                  <div className="text-sm" role="status">
                    <p className="font-medium">
                      {t("enrolled", { label: labelsT(label) })}
                    </p>
                    <Link
                      href="/participations"
                      className="mt-3 inline-block text-[13px] text-accent hover:underline"
                    >
                      {t("viewInParticipations")}
                    </Link>
                  </div>
                ) : !enrollChecked ? (
                  <div className="text-sm text-ink-3">
                    {t("checkingEnroll")}
                  </div>
                ) : enrollmentUnavailable ? (
                  enrollmentUnavailableNotice
                ) : (
                  <div className="grid gap-3">
                    {offering.enrollmentPolicy === "invite_only" ? (
                      <label className="block">
                        <span className="block text-[13px] text-ink-3">
                          {t("inviteCode")}
                        </span>
                        <input
                          value={inviteCode}
                          onChange={(e) => setInviteCode(e.target.value)}
                          className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm"
                        />
                      </label>
                    ) : null}
                    {offering.pricingEnabled ? (
                      <fieldset
                        className="grid gap-2"
                        data-testid="price-tier-picker"
                      >
                        <legend className="text-[13px] text-ink-3">
                          {t("chooseTier")}
                        </legend>
                        {priceTiers.length === 0 ? (
                          <p
                            className="text-[13px] text-ink-3"
                            data-testid="no-available-tier"
                          >
                            {t("noTierAvailable")}
                          </p>
                        ) : (
                          priceTiers.map((tier) => (
                            <label
                              key={tier.id}
                              className={`flex cursor-pointer items-center justify-between rounded-large border px-3 py-2 text-sm ${
                                tierId === tier.id
                                  ? "border-line-strong bg-soft-2 text-ink"
                                  : "border-line bg-card text-ink-2"
                              }`}
                              data-testid={`price-tier-${tier.id}`}
                            >
                              <span className="flex items-center gap-2">
                                <input
                                  type="radio"
                                  name="price-tier"
                                  value={tier.id}
                                  checked={tierId === tier.id}
                                  onChange={() => setTierId(tier.id)}
                                />
                                {tier.name}
                              </span>
                              <span className="font-medium">
                                ¥{formatAmount(tier.amountCents)}
                              </span>
                            </label>
                          ))
                        )}
                      </fieldset>
                    ) : null}
                    {offering.enrollmentPolicy === "request" ? (
                      <p className="text-[13px] text-ink-3">
                        {t("requestApprovalHint")}
                      </p>
                    ) : null}
                    {submitState.kind === "error" ? (
                      <p className="text-[13px] text-ink-3" role="alert">
                        {submitState.message}
                      </p>
                    ) : null}
                    {submitPhase === "reconcile_failed" ? (
                      // B2：重拉失败稳态，提交保持锁定，resync 是唯一出口。
                      <p className="text-[13px] text-ink-3" role="alert">
                        {t("reconcileFailed")}
                      </p>
                    ) : null}
                    {submitPhase === "reconcile_failed" ||
                    submitPhase === "reconciling" ? (
                      <button
                        type="button"
                        // 稳态可点（重新同步）；在途 disabled（B2 单飞语义）
                        disabled={submitPhase === "reconciling"}
                        onClick={() => void resync()}
                        className="join-button join-button--outline justify-self-start"
                        data-testid="resync-offering"
                      >
                        {submitPhase === "reconciling"
                          ? t("reconciling")
                          : t("resync")}
                      </button>
                    ) : (
                      <button
                        type="button"
                        disabled={
                          busy ||
                          (offering.pricingEnabled === true &&
                            priceTiers.length === 0)
                        }
                        onClick={() => void submit()}
                        className="join-button join-button--primary justify-self-start"
                      >
                        {busy
                          ? t("submitting")
                          : offering.pricingEnabled && paidTier
                            ? t("submitWithPay", {
                                amount: formatAmount(paidTier.amountCents),
                              })
                            : t("submit")}
                      </button>
                    )}
                  </div>
                )}
              </div>
            </aside>

            {offering.description ? (
              <section
                className="public-detail__about"
                aria-labelledby="public-detail-about-title"
              >
                <h2 id="public-detail-about-title">{t("aboutTitle")}</h2>
                <p>{offering.description}</p>
              </section>
            ) : null}

            <div className="public-detail__after">
              {kind === "course" && offering.slug ? (
                <CourseMapSection slug={offering.slug} />
              ) : null}

              {sponsorshipOpen ? (
                <section className="public-detail__sponsorship">
                  <h2>{t("sponsorTitle")}</h2>
                  <p className="mt-1 text-[13px] text-ink-3">
                    {t("sponsorDesc")}
                  </p>
                  <div className="mt-4 grid gap-2">
                    {sponsorshipTiers.map((tier) => (
                      <div
                        key={tier.id}
                        className="rounded-large border border-line bg-soft-2 p-3 text-sm"
                      >
                        <p className="flex items-center gap-2 font-medium">
                          {tier.name}
                          {tier.exclusive ? (
                            <span className="ld-badge-exclusive rounded-full px-2 py-0.5 text-[11px]">
                              {t("exclusive")}
                            </span>
                          ) : null}
                        </p>
                        {tier.amountSuggestion ? (
                          <p className="mt-0.5 text-[13px] text-ink-3">
                            {t("suggestAmount", {
                              amount: tier.amountSuggestion,
                            })}
                          </p>
                        ) : null}
                        {tier.benefits.length > 0 ? (
                          <p className="mt-0.5 text-[13px] text-ink-3">
                            {t("benefits", {
                              benefits: tier.benefits.join(" / "),
                            })}
                          </p>
                        ) : null}
                      </div>
                    ))}
                  </div>
                  <div className="mt-5 border-t border-line pt-5">
                    {!authed ? (
                      <div className="text-sm">
                        <Link
                          href={`/login?next=${encodeURIComponent(`/events/${offering.slug}`)}`}
                          className="join-button join-button--primary inline-block"
                        >
                          {t("loginToSponsor")}
                        </Link>
                        <p className="mt-2 text-[13px] text-ink-3">
                          {t("sponsorLoginHint")}
                        </p>
                      </div>
                    ) : userId ? (
                      <SponsorshipIntentForm
                        eventId={offering.id}
                        sponsorUserId={userId}
                        tiers={sponsorshipTiers}
                      />
                    ) : null}
                  </div>
                </section>
              ) : null}
            </div>
          </article>
        )}
      </div>

      {/* 批①桌面：收费报名的就地收银模态框（支付成功 onPaid 就地刷新报名态） */}
      {checkout ? (
        <PaymentCheckoutDialog
          enrollmentId={checkout.enrollmentId}
          amountCents={checkout.amountCents}
          tierName={checkout.tierName}
          title={checkout.title}
          onClose={() => setCheckout(null)}
          onPaid={() => void refetchEnrollment()}
        />
      ) : null}
    </PublicCatalogShell>
  );
}
