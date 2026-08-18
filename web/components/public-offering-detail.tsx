"use client";

/**
 * E-5 #50 公开宿主页 /events/[id] 与 /courses/[id]（游客可看详情，报名需登录）。
 *
 * - 详情：匿名读（open + public）；workspace 活动 / 非 open → 404 语义
 *   （读策略过滤 → get 返回 null）；
 * - 报名表单（J-Visitor → J-Learner）：
 *   - 未登录：引导 /login（登录后回到本页）；
 *   - open：直接提交 → confirmed；
 *   - request：提交 → 「申请审批中」中间态；
 *   - invite_only：邀请码输入（可空则后端报 invite_code_required）。
 */

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { useAuthed } from "@/lib/use-authed";
import {
  fetchPublicOffering,
  parseSponsorshipTiers,
  submitEnrollment,
} from "@/lib/public-offerings";
import SponsorshipIntentForm from "@/components/sponsorship-intent-form";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import {
  ENROLLMENT_POLICY_LABEL,
  OFFERING_LABEL,
  VISIBILITY_LABEL,
} from "@/lib/graphql/events";
import EventStatusTag from "@/components/event-status-tag";
import CourseMapSection from "@/components/learning/course-map-section";
import { formatAmount, parsePriceTiers } from "@/lib/payment";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import { fetchMyEnrollment, formatDeadline } from "@/lib/events";
import PaymentCheckoutDialog from "@/components/payment-checkout-dialog";

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

  const [state, setState] = useState<DetailState>({
    id: "",
    row: null,
    error: null,
  });
  const [inviteCode, setInviteCode] = useState("");
  const [busy, setBusy] = useState(false);
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
            error: e instanceof Error ? e.message : "加载失败",
          });
        }
      });

    return () => {
      cancelled = true;
    };
  }, [slug, kind]);

  const stale = state.id !== slug;
  const offering = stale ? null : state.row;
  const loadError = stale ? null : state.error;
  const enrollChecked = offering !== null && enrollForId === offering.id;
  const label = OFFERING_LABEL[kind];
  const listHref = kind === "event" ? "/events" : "/courses";

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
    // 收费目标必须选档（R5：报名选档 → 占位 → payment_pending）；全过期档
    // 由 priceTiers.length === 0 的表单分支挡住，此处防御重复
    if (offering.pricingEnabled && !tierId) {
      setSubmitState({
        kind: "error",
        message: "请先选择价格档位",
        enrollmentId: null,
      });
      return;
    }
    setBusy(true);
    setSubmitState({ kind: "idle", message: null, enrollmentId: null });
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
            message: "名额已保留，请在限定时间内完成支付",
            enrollmentId: res.result.id,
          });
          // 桌面：报名占位成功即弹收银模态框（不整页跳转）
          openCheckoutFor(res.result.id);
        } else if (status === "pending") {
          setSubmitState({
            kind: "pending",
            message: "申请已提交，等待审批",
            enrollmentId: null,
          });
        } else {
          setSubmitState({
            kind: "confirmed",
            message: "报名成功",
            enrollmentId: null,
          });
          router.refresh();
        }
      } else {
        // :tier_id_required / :tier_not_available / unique 冲突等 AshGraphql
        // 错误经翻译层映射为可读文案；未知错误走兜底，不透传 GraphQL 原文
        setSubmitState({
          kind: "error",
          message: translatePaymentError(res.errors[0]?.code, "提交失败"),
          enrollmentId: null,
        });
      }
    } catch (e: unknown) {
      setSubmitState({
        kind: "error",
        message: translatePaymentError(
          e instanceof Error ? e.message : null,
          "提交失败",
        ),
        enrollmentId: null,
      });
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="mx-auto w-full max-w-3xl px-4 py-10">
      <header className="mb-6">
        <p className="text-[13px] text-ink-3">
          <Link href="/" className="hover:text-ink">
            工作台
          </Link>
          {" › "}
          <Link href={listHref} className="hover:text-ink">
            {label}
          </Link>
          {" › "}
          <strong>{offering?.title ?? "详情"}</strong>
        </p>
      </header>

      {loadError ? (
        <div className="join-card" role="alert">
          加载失败：{loadError}
        </div>
      ) : stale ? (
        <div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
      ) : offering === null ? (
        <div className="join-card text-center">
          <h1 className="text-lg font-medium">该{label}不可访问</h1>
          <p className="mt-2 text-sm text-ink-3">
            仅工作台内部可见，或已结束。请登录后从工作台内访问。
          </p>
        </div>
      ) : (
        <>
          <div className="join-card !p-8">
            <p className="flex items-center gap-2">
              <EventStatusTag status={offering.status} />
              <span className="text-[13px] text-ink-3">
                {VISIBILITY_LABEL[offering.visibility]}
              </span>
            </p>
            <h1 className="mt-3 text-2xl font-semibold">{offering.title}</h1>
            <div className="mt-4 grid gap-2 text-sm text-ink-3">
              <span>
                报名策略：{ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy]}
              </span>
              <span>
                报名截止：{formatDeadline(offering.registrationDeadline)}
              </span>
              {offering.description ? (
                <p className="mt-3 whitespace-pre-wrap text-sm text-ink-3">
                  {offering.description}
                </p>
              ) : null}
            </div>

            <div className="mt-6 border-t border-line pt-5">
              {!authed ? (
                <div className="text-sm">
                  <Link
                    href={`/login?next=${encodeURIComponent(`/${kind === "event" ? "events" : "courses"}/${offering.slug}`)}`}
                    className="join-button join-button--primary inline-block"
                  >
                    登录后报名
                  </Link>
                  <p className="mt-2 text-[13px] text-ink-3">
                    报名免费，登录或注册后提交（J-Visitor → J-Learner）。
                  </p>
                </div>
              ) : submitState.kind === "confirmed" ||
                submitState.kind === "pending" ||
                submitState.kind === "payment_pending" ? (
                <div className="text-sm" role="status">
                  <p className="font-medium">
                    {submitState.kind === "confirmed"
                      ? "✓ 报名成功"
                      : submitState.kind === "payment_pending"
                        ? "⏳ 待支付（名额已保留）"
                        : "✓ 申请已提交"}
                  </p>
                  <p className="mt-1 text-[13px] text-ink-3">
                    {submitState.message}
                  </p>
                  {submitState.kind === "payment_pending" &&
                  submitState.enrollmentId ? (
                    <button
                      type="button"
                      onClick={() => openCheckoutFor(submitState.enrollmentId!)}
                      className="join-button join-button--primary mt-3 inline-block"
                      data-testid="public-enrollment-continue-pay"
                    >
                      继续支付
                    </button>
                  ) : (
                    <Link
                      href="/participations"
                      className="mt-3 inline-block text-[13px] text-accent hover:underline"
                    >
                      在「我的参与」查看报名状态
                    </Link>
                  )}
                </div>
              ) : myEnroll?.status === "payment_pending" ? (
                <div
                  className="text-sm"
                  role="status"
                  data-testid="public-enrollment-pending-card"
                >
                  <p className="font-medium">
                    ⏳ 名额已保留，请在限定时间内完成支付
                  </p>
                  <button
                    type="button"
                    onClick={() => openCheckoutFor(myEnroll!.id)}
                    className="join-button join-button--primary mt-3 inline-block"
                    data-testid="public-enrollment-pending-pay"
                  >
                    继续支付
                  </button>
                </div>
              ) : myEnroll?.status === "pending" ? (
                <div className="text-sm" role="status">
                  <p className="font-medium">
                    你已报名该{label}，申请审批中，通过后确认名额。
                  </p>
                  <Link
                    href="/participations"
                    className="mt-3 inline-block text-[13px] text-accent hover:underline"
                  >
                    在「我的参与」查看报名状态
                  </Link>
                </div>
              ) : myEnroll ? (
                <div className="text-sm" role="status">
                  <p className="font-medium">你已报名该{label}。</p>
                  <Link
                    href="/participations"
                    className="mt-3 inline-block text-[13px] text-accent hover:underline"
                  >
                    在「我的参与」查看报名状态
                  </Link>
                </div>
              ) : !enrollChecked ? (
                <div className="text-sm text-ink-3">正在确认你的报名状态…</div>
              ) : (
                <div className="grid gap-3">
                  {offering.enrollmentPolicy === "invite_only" ? (
                    <label className="block">
                      <span className="block text-[13px] text-ink-3">
                        邀请码（必填）
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
                        选择价格档位
                      </legend>
                      {priceTiers.length === 0 ? (
                        <p
                          className="text-[13px] text-ink-3"
                          data-testid="no-available-tier"
                        >
                          当前无可售档位，请联系组织者。
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
                      提交后需 Owner/Admin 审批，通过后确认名额。
                    </p>
                  ) : null}
                  {submitState.kind === "error" ? (
                    <p className="text-[13px] text-ink-3" role="alert">
                      {submitState.message}
                    </p>
                  ) : null}
                  <button
                    type="button"
                    disabled={busy}
                    onClick={() => void submit()}
                    className="join-button join-button--primary justify-self-start"
                  >
                    {busy
                      ? "提交中…"
                      : offering.pricingEnabled && paidTier
                        ? `报名并支付 ¥${formatAmount(paidTier.amountCents)}`
                        : "提交报名"}
                  </button>
                </div>
              )}
            </div>
          </div>

          {kind === "course" && offering.slug ? (
            <CourseMapSection slug={offering.slug} />
          ) : null}

          {sponsorshipOpen ? (
            <div className="join-card !p-8">
              <h2 className="text-lg font-semibold">赞助本场</h2>
              <p className="mt-1 text-[13px] text-ink-3">
                提交赞助意向，审批通过后权益生效（意向登记，不收款）。
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
                        <span className="rounded-full bg-amber-100 px-2 py-0.5 text-[11px] text-amber-800">
                          独占位
                        </span>
                      ) : null}
                    </p>
                    {tier.amountSuggestion ? (
                      <p className="mt-0.5 text-[13px] text-ink-3">
                        建议金额 ¥{tier.amountSuggestion}
                      </p>
                    ) : null}
                    {tier.benefits.length > 0 ? (
                      <p className="mt-0.5 text-[13px] text-ink-3">
                        权益：{tier.benefits.join(" / ")}
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
                      登录后赞助
                    </Link>
                    <p className="mt-2 text-[13px] text-ink-3">
                      赞助需登录全局账号（不自动成为工作台成员）。
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
            </div>
          ) : null}
        </>
      )}

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
    </main>
  );
}
