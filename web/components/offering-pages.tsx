"use client";

/**
 * E-11 #127 活动/课程共享页面组件（kind 参数化；events 与 courses 薄壳复用）。
 *
 * - 成员可见：本工作台非 draft offering（open/closed/cancelled）；
 *   Owner/Admin 可见全部生命周期（含 draft）；
 * - Owner/Admin 可操作：新建、元数据编辑（含 visibility 双向切换，D9）、
 *   launch/close/cancel（allowedTransitions 乐观门控，后端复验）；
 * - 数据唯一真实路径：fetchWorkspaceOfferings/fetchOffering（GraphQL）；
 *   加载/草稿状态按 wsId/id 键控派生，effect 内不做同步 setState。
 */

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import {
  allowedTransitions,
  canManageEvents,
  createOffering,
  fetchMyEnrollment,
  fetchOffering,
  fetchPendingCount,
  fetchWorkspaceOfferings,
  formatDeadline,
  transitionOffering,
  updateOffering,
} from "@/lib/events";
import type { EventTransition } from "@/lib/events";
import type {
  EnrollmentPolicy,
  OfferingItem,
  OfferingKind,
  Visibility,
} from "@/lib/graphql/events";
import {
  ENROLLMENT_POLICIES,
  ENROLLMENT_POLICY_LABEL,
  OFFERING_LABEL,
  VISIBILITIES,
  VISIBILITY_LABEL,
} from "@/lib/graphql/events";
import WorkspaceShell from "@/components/workspace-shell";
import EventStatusTag from "@/components/event-status-tag";
import SpeakerInvitationPanel from "@/components/speaker-invitation-panel";
import InviteBatchPanel from "@/components/invite-batch-panel";
import { Icon } from "@/components/icons";
import SponsorshipManagement from "@/components/sponsorship-management";
import { formatAmount, parsePriceTiers } from "@/lib/payment";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import {
  parseSponsorshipTiers,
  submitEnrollment,
} from "@/lib/public-offerings";
import { useAuthed } from "@/lib/use-authed";
import PaymentCheckoutDialog from "@/components/payment-checkout-dialog";

const TRANSITION_LABEL: Record<EventTransition, string> = {
  launch: "transitionLaunch",
  close: "transitionClose",
  cancel: "transitionCancel",
};

/**
 * 保存/操作失败文案映射（U2 #127）：AshGraphql 自动 mutation 的 errors[0].message
 * 多为 "Input is invalid"（字段级文案在 short_message）——已知后端模式映射为可读文案，
 * 未知一律走兜底，不透传 GraphQL 原文。
 */
function friendlyOfferingError(
  error:
    | { message?: string | null; short_message?: string | null }
    | null
    | undefined,
  fallback: string,
): string {
  const raw = [error?.message, error?.short_message].filter(Boolean).join("\n");
  if (!raw) return fallback;
  if (/greater than or equal to 1/.test(raw)) {
    return "saveCapacityError";
  }
  if (/cannot (launch|close|cancel) from status=/.test(raw)) {
    return "saveStateError";
  }
  if (/failed: status changed concurrently/.test(raw)) {
    return "saveConcurrentError";
  }
  return fallback;
}

function toLocalInput(datetime: string | null): string {
  if (!datetime) return "";
  const d = new Date(datetime);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function fromLocalInput(value: string): string | null {
  if (!value) return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function Field({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div>
      <span className="block text-[13px] text-ink-3">{label}</span>
      <span className="mt-0.5 block text-sm text-ink">{children}</span>
    </div>
  );
}

/* ---------------- 列表页 ---------------- */

interface OfferingsState {
  wsId: string;
  rows: OfferingItem[] | null;
  error: string | null;
}

function OfferingRow({
  offering,
  slug,
  kind,
}: {
  offering: OfferingItem;
  slug: string;
  kind: OfferingKind;
}) {
  const t = useTranslations("offerings");
  const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;
  return (
    <Link
      href={`${base}/${offering.id}`}
      className="flex items-center gap-4 rounded-large border border-line bg-card p-5 transition-colors hover:border-line-strong"
    >
      <span className="min-w-0 flex-1">
        <span className="flex items-center gap-2">
          <span className="block truncate text-sm font-medium text-ink">
            {offering.title}
          </span>
          <EventStatusTag status={offering.status} />
        </span>
        <span className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[13px] leading-5 text-ink-3">
          <span>{ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy]}</span>
          <span>·</span>
          <span>{VISIBILITY_LABEL[offering.visibility]}</span>
          <span>·</span>
          <span>
            {t("deadlineLabel", {
              deadline: formatDeadline(offering.registrationDeadline),
            })}
          </span>
        </span>
      </span>
      <span className="flex-none text-ink-3">
        <Icon name="arrow" />
      </span>
    </Link>
  );
}

export function OfferingsListPage({
  slug,
  kind,
}: {
  slug: string;
  kind: OfferingKind;
}) {
  const t = useTranslations("offerings");
  const tCommon = useTranslations("common");
  const { ws, loading: wsLoading } = useWorkspaceBySlugWrapper(slug);
  const [state, setState] = useState<OfferingsState>({
    wsId: "",
    rows: null,
    error: null,
  });

  useEffect(() => {
    if (!ws) return;

    let cancelled = false;

    fetchWorkspaceOfferings(ws.id, kind)
      .then((rows) => {
        if (!cancelled) setState({ wsId: ws.id, rows, error: null });
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setState({
            wsId: ws.id,
            rows: null,
            error: e instanceof Error ? e.message : t("loadFailed"),
          });
        }
      });

    return () => {
      cancelled = true;
    };
  }, [ws, kind, t]);

  const stale = ws ? state.wsId !== ws.id : false;
  const rows = stale ? null : state.rows;
  const loadError = stale ? null : state.error;
  const manage = ws ? canManageEvents(ws.myRoleNames) : false;
  const label = OFFERING_LABEL[kind];
  const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;

  return (
    <WorkspaceShell slug={slug}>
      <div className="ws-page-main__inner">
        <div
          className="ws-page-breadcrumb"
          aria-label={tCommon("breadcrumbAria")}
        >
          <Link href="/">{t("breadcrumbHome")}</Link>
          <span>›</span>
          <Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
          <span>›</span>
          <strong>{label}</strong>
        </div>

        <header className="ws-page-heading">
          <div>
            <h1>{label}</h1>
            <p>{t("subtitle", { label })}</p>
          </div>
          {manage && ws ? (
            <Link
              href={`${base}/new`}
              className="inline-flex items-center gap-2 rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink"
            >
              <Icon name="plus" />
              {t("createNew", { label })}
            </Link>
          ) : null}
        </header>

        {loadError ? (
          <div className="rounded-large border border-line bg-card p-6 text-sm text-ink-3">
            {t("loadFailed")}
          </div>
        ) : wsLoading || rows === null ? (
          <div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
        ) : rows.length === 0 ? (
          <div className="rounded-large border border-dashed border-line bg-card p-10 text-center text-sm text-ink-3">
            {t("empty", { label })}
            {manage ? t("emptyCreateHint", { label }) : t("emptyWaitHint")}
          </div>
        ) : (
          <div className="grid gap-3">
            {rows.map((offering) => (
              <OfferingRow
                key={offering.id}
                offering={offering}
                slug={slug}
                kind={kind}
              />
            ))}
          </div>
        )}
      </div>
    </WorkspaceShell>
  );
}

/* ---------------- 详情/管理页 ---------------- */

/** research_requirements(JsonString)与自由文本互转(U8/R12:Q10 自由文本语义) */
function parseResearchText(json: string | null | undefined): string {
  if (!json) return "";
  try {
    const parsed = JSON.parse(json) as unknown;
    if (typeof parsed === "string") return parsed;
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      const note = (parsed as Record<string, unknown>).note;
      if (typeof note === "string") return note;
    }
  } catch {
    // 非法 JSON 原样展示
    return typeof json === "string" ? json : "";
  }
  return "";
}

function buildResearchJson(text: string): string {
  return JSON.stringify({ note: text });
}

/** 教研 run 状态展示词(U8 教研状态露出) */
const RESEARCH_RUN_STATUS_LABEL: Record<string, string> = {
  pending: "runStatusPending",
  running: "runStatusRunning",
  waiting: "runStatusWaiting",
  succeeded: "runStatusSucceeded",
  failed: "runStatusFailed",
  cancelled: "runStatusCancelled",
  expired: "runStatusExpired",
};

interface OfferingState {
  id: string;
  row: OfferingItem | null;
  error: string | null;
}

interface MetaDraft {
  offeringId: string;
  title: string;
  enrollmentPolicy: EnrollmentPolicy;
  capacity: string;
  deadline: string;
  /** 教研需求自由文本(U8/R12,仅 course;原文透传 research_requirements) */
  researchRequirements: string;
}

export function OfferingDetailPage({
  slug,
  id,
  kind,
}: {
  slug: string;
  id: string;
  kind: OfferingKind;
}) {
  const t = useTranslations("offerings");
  const tCommon = useTranslations("common");
  const {
    ws,
    readOnlyVisitor,
    loading: wsLoading,
  } = useWorkspaceBySlugWrapper(slug);
  const { userId } = useAuthed();
  const translatePaymentError = usePaymentErrorTranslator();
  const [state, setState] = useState<OfferingState>({
    id: "",
    row: null,
    error: null,
  });
  const [metaDraft, setMetaDraft] = useState<MetaDraft | null>(null);
  const [saveBusy, setSaveBusy] = useState(false);
  const [saveMessage, setSaveMessage] = useState<string | null>(null);
  const [busyTransition, setBusyTransition] = useState<EventTransition | null>(
    null,
  );
  // close/cancel 不可逆（终态 v1 不可恢复）：二次点击确认（U2 #127）；launch 可逆性高不加
  const [confirmingTransition, setConfirmingTransition] =
    useState<EventTransition | null>(null);
  const [pendingState, setPendingState] = useState<{
    id: string;
    status: "loading" | "ok" | "error";
    value: number;
  }>({ id: "", status: "loading", value: 0 });
  // E-5 #50 G3：工作台详情页报名入口（活动 open + 本人无既有报名才显示）。
  // 支付接续：fetchMyEnrollment 回活跃报名行（id+status），渲染分四态——
  // payment_pending → 待支付卡（去支付入口）；pending → 审批中；confirmed →
  // 已报名；无行 → 报名表单。
  const [enrollState, setEnrollState] = useState<{
    id: string;
    enrollment: { id: string; status: string } | null;
    status: "loading" | "ok" | "error";
  }>({ id: "", enrollment: null, status: "loading" });
  const [enrollBusy, setEnrollBusy] = useState(false);
  const [submitState, setSubmitState] = useState<{
    kind: "idle" | "confirmed" | "pending" | "payment_pending" | "error";
    message: string | null;
    /** payment_pending 态的去支付入口目标（R5 报名 id） */
    enrollmentId?: string | null;
  }>({ kind: "idle", message: null });
  // 收银模态框（批①桌面）：payment_pending 报名的就地支付上下文；null = 关闭
  const [checkout, setCheckout] = useState<{
    enrollmentId: string;
    amountCents: number | null;
    tierName: string | null;
    title: string;
  } | null>(null);

  useEffect(() => {
    if (!id) return;
    let cancelled = false;

    fetchOffering(id, kind)
      .then((row) => {
        if (!cancelled) setState({ id, row, error: null });
      })
      .catch(() => {
        if (!cancelled) {
          setState({
            id,
            row: null,
            error: t("loadFailed"),
          });
        }
      });

    return () => {
      cancelled = true;
    };
  }, [id, kind, t]);

  // 我的既有报名（防重复报名；读策略仅本人可见）
  useEffect(() => {
    if (!id || !userId) return;
    let cancelled = false;

    fetchMyEnrollment(id, kind, userId)
      .then((enrollment) => {
        if (!cancelled) setEnrollState({ id, enrollment, status: "ok" });
      })
      .catch(() => {
        // 失败 ≠ 已报名：入口不显示（不误报），错误态不阻塞页面其余部分
        if (!cancelled)
          setEnrollState({ id, enrollment: null, status: "error" });
      });

    return () => {
      cancelled = true;
    };
  }, [id, kind, userId]);

  // 支付成功后就地刷新报名态（模态框 onPaid → payment_pending → confirmed）
  const refetchEnrollment = useCallback(async () => {
    if (!id || !userId) return;
    try {
      const enrollment = await fetchMyEnrollment(id, kind, userId);
      setEnrollState({ id, enrollment, status: "ok" });
    } catch {
      // 刷新失败保持现态；手动刷新页面仍可恢复
    }
  }, [id, kind, userId]);

  const stale = state.id !== id;
  const offering = stale ? null : state.row;

  // 收费目标：可售档位（R2 后端已过滤过期档）与所选档（R5 报名须选档）
  const priceTiers = parsePriceTiers(offering?.availablePriceTiers);
  const [tierId, setTierId] = useState<string | null>(null);
  const paidTier = priceTiers.find((t) => t.id === tierId) ?? null;
  // 开收银模态框：收费目标带所选档上下文（金额/档名/标题），复访承接可不带
  function openCheckoutFor(enrollmentId: string) {
    const tier = priceTiers.find((t) => t.id === tierId) ?? null;
    setCheckout({
      enrollmentId,
      amountCents: tier?.amountCents ?? null,
      tierName: tier?.name ?? null,
      title: offering?.title ?? "",
    });
  }

  const loadError = stale ? null : state.error;
  const manage = ws ? canManageEvents(ws.myRoleNames) : false;

  // pending 报名数（报名数据视图：request 策略待审批；仅管理视角发起，
  // 普通成员/匿名不发请求——U2 #127）
  useEffect(() => {
    if (!id || !manage) return;
    let cancelled = false;

    fetchPendingCount(id, kind)
      .then((n) => {
        if (!cancelled) setPendingState({ id, status: "ok", value: n });
      })
      .catch(() => {
        // 失败 ≠ 0：不得把未知数据误报为「无人待审批」（复审 BLOCKING 3）
        if (!cancelled) setPendingState({ id, status: "error", value: 0 });
      });

    return () => {
      cancelled = true;
    };
  }, [id, kind, manage, t]);
  const transitions = offering ? allowedTransitions(offering.status) : [];
  const label = OFFERING_LABEL[kind];
  const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;

  const activeDraft: MetaDraft | null =
    metaDraft && metaDraft.offeringId === offering?.id
      ? metaDraft
      : offering
        ? {
            offeringId: offering.id,
            title: offering.title,
            enrollmentPolicy: offering.enrollmentPolicy,
            capacity:
              offering.capacity === null ? "" : String(offering.capacity),
            deadline: toLocalInput(offering.registrationDeadline),
            researchRequirements: parseResearchText(
              offering.researchRequirements,
            ),
          }
        : null;

  async function saveVisibility(next: Visibility) {
    if (!offering) return;
    setSaveBusy(true);
    setSaveMessage(null);
    try {
      const res = await updateOffering(offering.id, kind, { visibility: next });
      if (res.result) {
        setState({
          id: offering.id,
          row: { ...offering, visibility: res.result.visibility },
          error: null,
        });
        setSaveMessage(t("saved"));
      } else {
        setSaveMessage(
          t(friendlyOfferingError(res.errors[0], "saveFailedRetry")),
        );
      }
    } catch (e: unknown) {
      setSaveMessage(
        t(
          friendlyOfferingError(
            e instanceof Error ? { message: e.message } : null,
            "saveFailedRetry",
          ),
        ),
      );
    } finally {
      setSaveBusy(false);
    }
  }

  async function saveMeta() {
    if (!offering || !activeDraft) return;
    setSaveBusy(true);
    setSaveMessage(null);
    try {
      const res = await updateOffering(offering.id, kind, {
        title: activeDraft.title,
        enrollmentPolicy: activeDraft.enrollmentPolicy,
        capacity:
          activeDraft.capacity === "" ? null : Number(activeDraft.capacity),
        registrationDeadline: fromLocalInput(activeDraft.deadline),
        ...(kind === "course"
          ? {
              researchRequirements: buildResearchJson(
                activeDraft.researchRequirements,
              ),
            }
          : {}),
      });
      if (res.result) {
        setState({
          id: offering.id,
          row: {
            ...offering,
            title: res.result.title,
            enrollmentPolicy: res.result.enrollmentPolicy,
            capacity: res.result.capacity,
            registrationDeadline: res.result.registrationDeadline,
          },
          error: null,
        });
        setMetaDraft(null);
        setSaveMessage(t("saved"));
      } else {
        setSaveMessage(
          t(friendlyOfferingError(res.errors[0], "saveFailedRetry")),
        );
      }
    } catch (e: unknown) {
      setSaveMessage(
        t(
          friendlyOfferingError(
            e instanceof Error ? { message: e.message } : null,
            "saveFailedRetry",
          ),
        ),
      );
    } finally {
      setSaveBusy(false);
    }
  }

  async function runTransition(tr: EventTransition) {
    if (!offering) return;
    setBusyTransition(tr);
    try {
      const res = await transitionOffering(offering.id, kind, tr);
      if (res.result) {
        setState({
          id: offering.id,
          row: { ...offering, status: res.result.status },
          error: null,
        });
      } else {
        setSaveMessage(
          t(friendlyOfferingError(res.errors[0], "actionFailedRetry")),
        );
      }
    } catch (e: unknown) {
      setSaveMessage(
        t(
          friendlyOfferingError(
            e instanceof Error ? { message: e.message } : null,
            "actionFailedRetry",
          ),
        ),
      );
    } finally {
      setBusyTransition(null);
    }
  }

  // E-5 #50 G3：报名入口显示条件 = 活动 open + 当前用户无既有报名（query 就绪且
  // 未报）。复用 submitEnrollment（createEnrollment mutation，鉴权后端管）。
  async function submitForMe() {
    if (!offering || !userId) return;
    // 收费目标必须选档（R5：报名选档 → 占位 → payment_pending）
    if (offering.pricingEnabled && !tierId) {
      setSubmitState({ kind: "error", message: t("pickTierFirst") });
      return;
    }
    setEnrollBusy(true);
    setSubmitState({ kind: "idle", message: null });
    try {
      const res = await submitEnrollment({
        eventId: kind === "event" ? offering.id : undefined,
        courseId: kind === "course" ? offering.id : undefined,
        userId,
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
          });
        } else {
          setSubmitState({ kind: "confirmed", message: t("enrolledMsg") });
        }
      } else {
        setSubmitState({
          kind: "error",
          message: translatePaymentError(res.errors[0]?.code, t("submitFailed")),
        });
      }
    } catch (e: unknown) {
      setSubmitState({
        kind: "error",
        message: translatePaymentError(
          e instanceof Error ? e.message : null,
          t("submitFailed"),
        ),
      });
    } finally {
      setEnrollBusy(false);
    }
  }

  return (
    <WorkspaceShell slug={slug}>
      <div className="ws-page-main__inner">
        <div
          className="ws-page-breadcrumb"
          aria-label={tCommon("breadcrumbAria")}
        >
          <Link href="/">{t("breadcrumbHome")}</Link>
          <span>›</span>
          <Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
          <span>›</span>
          <Link href={base}>{label}</Link>
          <span>›</span>
          <strong>{offering?.title ?? t("detailFallback")}</strong>
        </div>

        {loadError ? (
          <div className="rounded-large border border-line bg-card p-6 text-sm text-ink-3">
            {t("loadFailed")}
          </div>
        ) : offering === null && !stale ? (
          <div className="join-card text-center">
            <h1 className="text-lg font-medium">
              {t("notAccessible", { label })}
            </h1>
            <p className="mt-2 text-sm text-ink-3">{t("notAccessibleDesc")}</p>
          </div>
        ) : offering === null ? (
          <div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
        ) : (
          <>
            <header className="ws-page-heading">
              <div>
                <h1>{offering.title}</h1>
                <p className="flex items-center gap-2">
                  <EventStatusTag status={offering.status} />
                  <span className="text-ink-3">
                    {VISIBILITY_LABEL[offering.visibility]}
                  </span>
                </p>
              </div>
            </header>

            <div className="grid gap-4 sm:grid-cols-2">
              <div className="rounded-large border border-line bg-card p-6">
                <h2 className="text-sm font-medium text-ink">
                  {t("basicInfo")}
                </h2>
                <div className="mt-4 grid gap-4">
                  <Field label={t("fieldPolicy")}>
                    {ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy]}
                  </Field>
                  <Field label={t("fieldDeadline")}>
                    {formatDeadline(offering.registrationDeadline)}
                  </Field>
                  <Field label={t("fieldCapacity")}>
                    {offering.capacity === null
                      ? t("capacityUnlimited", {
                          count: offering.confirmedCount ?? 0,
                        })
                      : t("capacityCount", {
                          confirmed: offering.confirmedCount ?? 0,
                          capacity: offering.capacity,
                        })}
                  </Field>
                  {manage ? (
                    <Field label={t("fieldPending")}>
                      {pendingState.id !== id ||
                      pendingState.status === "loading"
                        ? "—"
                        : pendingState.status === "error"
                          ? t("loadFailed")
                          : pendingState.value}
                    </Field>
                  ) : null}
                </div>
              </div>

              {manage && kind === "course" ? (
                <div
                  className="rounded-large border border-line bg-card p-6"
                  data-testid="research-status"
                >
                  <h2 className="text-sm font-medium text-ink">
                    {t("researchTitle")}
                  </h2>
                  <dl className="mt-3 grid gap-2 text-sm">
                    <div className="flex items-center gap-2">
                      <dt className="text-ink-3">{t("runStatusLabel")}</dt>
                      <dd
                        className="text-ink"
                        data-testid="research-run-status"
                      >
                        {offering.workflowRun?.status
                          ? (t(
                              RESEARCH_RUN_STATUS_LABEL[
                                offering.workflowRun.status
                              ],
                            ) ?? offering.workflowRun.status)
                          : offering.workflowRunId
                            ? t("linked")
                            : t("notInstantiated")}
                      </dd>
                    </div>
                    <div className="flex items-center gap-2">
                      <dt className="text-ink-3">
                        {t("contentCompletion")}
                      </dt>
                      <dd
                        className="text-ink"
                        data-testid="research-content-status"
                      >
                        {offering.workflowRun?.status === "succeeded"
                          ? t("issueSubmitted")
                          : t("awaitResearch")}
                      </dd>
                    </div>
                  </dl>
                </div>
              ) : null}

              {manage && activeDraft ? (
                <div className="rounded-large border border-line bg-card p-6">
                  <h2 className="text-sm font-medium text-ink">
                    {t("editMeta")}
                  </h2>

                  <div className="mt-4 grid gap-3">
                    <label className="block">
                      <span className="block text-[13px] text-ink-3">
                        {t("fieldTitle")}
                      </span>
                      <input
                        value={activeDraft.title}
                        onChange={(e) =>
                          setMetaDraft({
                            ...activeDraft,
                            title: e.target.value,
                          })
                        }
                        className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
                      />
                    </label>

                    <label className="block">
                      <span className="block text-[13px] text-ink-3">
                        {t("fieldPolicy")}
                      </span>
                      <select
                        value={activeDraft.enrollmentPolicy}
                        onChange={(e) =>
                          setMetaDraft({
                            ...activeDraft,
                            enrollmentPolicy: e.target
                              .value as EnrollmentPolicy,
                          })
                        }
                        className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
                      >
                        {ENROLLMENT_POLICIES.map((p) => (
                          <option key={p} value={p}>
                            {ENROLLMENT_POLICY_LABEL[p]}
                          </option>
                        ))}
                      </select>
                    </label>

                    <label className="block">
                      <span className="block text-[13px] text-ink-3">
                        {t("capacityHint")}
                      </span>
                      <input
                        type="number"
                        min={1}
                        value={activeDraft.capacity}
                        onChange={(e) =>
                          setMetaDraft({
                            ...activeDraft,
                            capacity: e.target.value,
                          })
                        }
                        className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
                      />
                    </label>

                    <label className="block">
                      <span className="block text-[13px] text-ink-3">
                        {t("deadlineHint")}
                      </span>
                      <input
                        type="datetime-local"
                        value={activeDraft.deadline}
                        onChange={(e) =>
                          setMetaDraft({
                            ...activeDraft,
                            deadline: e.target.value,
                          })
                        }
                        className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
                      />
                    </label>
                    {kind === "course" ? (
                      <label className="block">
                        <span className="block text-[13px] text-ink-3">
                          {t("researchNeed")}
                        </span>
                        <textarea
                          data-testid="research-requirements-input"
                          rows={4}
                          value={activeDraft.researchRequirements}
                          onChange={(e) =>
                            setMetaDraft({
                              ...activeDraft,
                              researchRequirements: e.target.value,
                            })
                          }
                          className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
                          placeholder={t("researchPlaceholder")}
                        />
                      </label>
                    ) : null}

                    <button
                      type="button"
                      disabled={saveBusy || activeDraft.title.trim() === ""}
                      onClick={() => void saveMeta()}
                      className="mt-1 rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
                    >
                      {saveBusy ? t("savingMeta") : t("saveMeta")}
                    </button>
                  </div>
                </div>
              ) : null}
            </div>

            {/* E-5 #50 G3：工作台详情页报名入口（open + 本人无既有报名；复用
						    submitEnrollment，鉴权后端管） */}
            {!wsLoading &&
            ws &&
            !readOnlyVisitor &&
            offering.status === "open" &&
            userId !== null &&
            enrollState.id === id &&
            enrollState.status === "ok" ? (
              <div className="mt-4 rounded-large border border-line bg-card p-6">
                <h2 className="text-sm font-medium text-ink">
                  {t("enrollTitle")}
                </h2>
                <div className="mt-3 text-sm">
                  {submitState.kind === "confirmed" ||
                  submitState.kind === "pending" ||
                  submitState.kind === "payment_pending" ? (
                    <div role="status" className="grid gap-2">
                      <p className="text-ink">
                        {submitState.kind === "confirmed"
                          ? t("enrolledConfirm")
                          : submitState.kind === "payment_pending"
                            ? t("pendingPay")
                            : t("submitted")}
                        {submitState.message
                          ? `（${submitState.message}）`
                          : ""}
                      </p>
                      {submitState.kind === "payment_pending" &&
                      submitState.enrollmentId ? (
                        <button
                          type="button"
                          onClick={() =>
                            openCheckoutFor(submitState.enrollmentId!)
                          }
                          className="justify-self-start rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line"
                          data-testid="enrollment-continue-pay"
                        >
                          {t("continuePay")}
                        </button>
                      ) : null}
                    </div>
                  ) : enrollState.enrollment?.status === "payment_pending" ? (
                    <div
                      className="grid gap-2"
                      role="status"
                      data-testid="enrollment-pending-card"
                    >
                      <p className="text-ink">{t("slotReserved")}</p>
                      <button
                        type="button"
                        onClick={() =>
                          openCheckoutFor(enrollState.enrollment!.id)
                        }
                        data-testid="enrollment-pending-pay"
                        className="justify-self-start rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line"
                      >
                        {t("continuePay")}
                      </button>
                    </div>
                  ) : enrollState.enrollment?.status === "pending" ? (
                    <p className="text-[13px] text-ink-3">
                      {t("pendingApproval", { label })}
                    </p>
                  ) : enrollState.enrollment ? (
                    <p className="text-[13px] text-ink-3">
                      {t("enrolled", { label })}
                    </p>
                  ) : (
                    <div className="grid gap-3">
                      {submitState.kind === "error" ? (
                        <p className="text-[13px] text-ink-3" role="alert">
                          {submitState.message}
                        </p>
                      ) : null}
                      {offering.enrollmentPolicy === "request" ? (
                        <p className="text-[13px] text-ink-3">
                          {t("requestHint")}
                        </p>
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
                            <p className="text-[13px] text-ink-3">
                              {t("noTier")}
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
                      <button
                        type="button"
                        disabled={enrollBusy}
                        onClick={() => void submitForMe()}
                        className="justify-self-start rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
                      >
                        {enrollBusy
                          ? t("submitting")
                          : offering.pricingEnabled && paidTier
                            ? t("submitWithPay", {
                                amount: formatAmount(paidTier.amountCents),
                              })
                            : t("submit")}
                      </button>
                    </div>
                  )}
                </div>
              </div>
            ) : null}

            {manage ? (
              <div className="mt-4 rounded-large border border-line bg-card p-6">
                <h2 className="text-sm font-medium text-ink">
                  {t("lifecycle")}
                </h2>

                <div className="mt-3">
                  <span className="block text-[13px] text-ink-3">
                    {t("visibilityHint")}
                  </span>
                  <div className="mt-2 flex gap-2">
                    {VISIBILITIES.map((v) => (
                      <button
                        key={v}
                        type="button"
                        disabled={saveBusy || offering.visibility === v}
                        onClick={() => void saveVisibility(v)}
                        className={`rounded-full border px-3 py-1 text-[13px] ${
                          offering.visibility === v
                            ? "border-accent bg-soft-2 text-accent"
                            : "border-line text-ink-3 hover:border-line-strong"
                        }`}
                      >
                        {VISIBILITY_LABEL[v]}
                      </button>
                    ))}
                  </div>
                </div>

                <div className="mt-5 flex flex-wrap gap-2">
                  {transitions.map((tr) =>
                    confirmingTransition === tr ? (
                      <div
                        key={tr}
                        className="w-full rounded-large border border-line bg-soft-2 p-3"
                      >
                        <p
                          className="text-[13px] text-ink-3"
                          aria-live="polite"
                        >
                          {tr === "close"
                            ? t("transitionConfirmClose", { label })
                            : t("transitionConfirmCancel", { label })}
                        </p>
                        <div className="mt-2 flex gap-2">
                          <button
                            type="button"
                            disabled={busyTransition !== null}
                            onClick={() => void runTransition(tr)}
                            className="rounded-large border border-danger px-3 py-1.5 text-[13px] text-danger disabled:opacity-50"
                          >
                            {busyTransition === tr
                              ? t("processing")
                              : t("transitionConfirm", {
                                  transition: t(TRANSITION_LABEL[tr]),
                                })}
                          </button>
                          <button
                            type="button"
                            disabled={busyTransition !== null}
                            onClick={() => setConfirmingTransition(null)}
                            className="rounded-large border border-line px-3 py-1.5 text-[13px] text-ink-3 disabled:opacity-50"
                          >
                            {t("back")}
                          </button>
                        </div>
                      </div>
                    ) : (
                      <button
                        key={tr}
                        type="button"
                        disabled={busyTransition !== null}
                        onClick={() => {
                          if (tr === "close" || tr === "cancel") {
                            setConfirmingTransition(tr);
                          } else {
                            void runTransition(tr);
                          }
                        }}
                        className="rounded-large border border-line bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line-strong disabled:opacity-50"
                      >
                        {busyTransition === tr
                          ? t("processing")
                          : t(TRANSITION_LABEL[tr])}
                      </button>
                    ),
                  )}
                  {transitions.length === 0 ? (
                    <span className="text-[13px] text-ink-3">
                      {t("terminalNote", { label })}
                    </span>
                  ) : null}
                </div>

                {saveMessage ? (
                  <p className="mt-3 text-[13px] text-ink-3">{saveMessage}</p>
                ) : null}
              </div>
            ) : null}

            {manage && offering.enrollmentPolicy === "invite_only" ? (
              <InviteBatchPanel
                kind={kind}
                offeringId={offering.id}
                offeringStatus={offering.status}
                workspaceId={offering.workspaceId ?? ws?.id ?? ""}
              />
            ) : null}

            {kind === "event" ? (
              <div className="mt-4">
                <SponsorshipManagement
                  target={{
                    kind: "event",
                    id: offering.id,
                    workspaceId: offering.workspaceId ?? "",
                  }}
                  tiers={parseSponsorshipTiers(offering.sponsorshipTiers)}
                  manage={manage}
                  onSaveTiers={async (tiers) => {
                    try {
                      const res = await updateOffering(offering.id, kind, {
                        sponsorshipTiers: tiers.map((t) => JSON.stringify(t)),
                      });
                      if (res.result) {
                        setState({
                          id: offering.id,
                          row: {
                            ...offering,
                            sponsorshipTiers: tiers.map((t) =>
                              JSON.stringify(t),
                            ),
                          },
                          error: null,
                        });
                        return true;
                      }
                      setSaveMessage(res.errors[0]?.message ?? t("saveFail"));
                      return false;
                    } catch (e: unknown) {
                      setSaveMessage(
                        e instanceof Error ? e.message : t("saveFail"),
                      );
                      return false;
                    }
                  }}
                />
              </div>
            ) : null}

            {/* E-4 #49：Speaker 邀请（仅 Event；Owner/Admin 入口） */}
            {manage && kind === "event" ? (
              <SpeakerInvitationPanel
                eventId={offering.id}
                eventSlug={offering.slug}
                workspaceId={offering.workspaceId ?? ws?.id ?? ""}
              />
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
      </div>
    </WorkspaceShell>
  );
}

/* ---------------- 新建页 ---------------- */

export function OfferingNewPage({
  slug,
  kind,
}: {
  slug: string;
  kind: OfferingKind;
}) {
  const t = useTranslations("offerings");
  const tCommon = useTranslations("common");
  const router = useRouter();
  const { ws, loading: wsLoading } = useWorkspaceBySlugWrapper(slug);

  const [title, setTitle] = useState("");
  const [enrollmentPolicy, setEnrollmentPolicy] =
    useState<EnrollmentPolicy>("open");
  const [visibility, setVisibility] = useState<Visibility>("public");
  const [capacity, setCapacity] = useState("");
  const [deadline, setDeadline] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const manage = ws ? canManageEvents(ws.myRoleNames) : false;
  const label = OFFERING_LABEL[kind];
  const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;

  async function submit() {
    if (!ws) return;
    setBusy(true);
    setError(null);
    try {
      const res = await createOffering(ws.id, kind, {
        title: title.trim(),
        enrollmentPolicy,
        visibility,
        capacity: capacity === "" ? null : Number(capacity),
        registrationDeadline: deadline
          ? new Date(deadline).toISOString()
          : null,
      });
      if (res.result) {
        router.push(`${base}/${res.result.id}`);
      } else {
        setError(res.errors[0]?.message ?? t("createFailed"));
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : t("createFailed"));
    } finally {
      setBusy(false);
    }
  }

  if (wsLoading) {
    return (
      <WorkspaceShell slug={slug}>
        <div className="ws-page-main__inner">
          <div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
        </div>
      </WorkspaceShell>
    );
  }

  if (!manage) {
    return (
      <WorkspaceShell slug={slug}>
        <div className="ws-page-main__inner">
          <div className="rounded-large border border-line bg-card p-10 text-center text-sm text-ink-3">
            {t("ownerOnly", { label })}
            <Link href={base} className="ml-2 text-accent">
              {t("backToList", { label })}
            </Link>
          </div>
        </div>
      </WorkspaceShell>
    );
  }

  return (
    <WorkspaceShell slug={slug}>
      <div className="ws-page-main__inner">
        <div
          className="ws-page-breadcrumb"
          aria-label={tCommon("breadcrumbAria")}
        >
          <Link href="/">{t("breadcrumbHome")}</Link>
          <span>›</span>
          <Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
          <span>›</span>
          <Link href={base}>{label}</Link>
          <span>›</span>
          <strong>{t("createTitle", { label })}</strong>
        </div>

        <header className="ws-page-heading">
          <div>
            <h1>{t("createTitle", { label })}</h1>
            <p>{t("createSubtitle")}</p>
          </div>
        </header>

        <div className="max-w-xl rounded-large border border-line bg-card p-6">
          <div className="grid gap-4">
            <label className="block">
              <span className="block text-[13px] text-ink-3">
                {t("titleRequired")}
              </span>
              <input
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
              />
            </label>

            <label className="block">
              <span className="block text-[13px] text-ink-3">
                {t("fieldPolicy")}
              </span>
              <select
                value={enrollmentPolicy}
                onChange={(e) =>
                  setEnrollmentPolicy(e.target.value as EnrollmentPolicy)
                }
                className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
              >
                {ENROLLMENT_POLICIES.map((p) => (
                  <option key={p} value={p}>
                    {ENROLLMENT_POLICY_LABEL[p]}
                  </option>
                ))}
              </select>
            </label>

            <div>
              <span className="block text-[13px] text-ink-3">
                {t("visibility")}
              </span>
              <div className="mt-2 flex gap-2">
                {VISIBILITIES.map((v) => (
                  <button
                    key={v}
                    type="button"
                    onClick={() => setVisibility(v)}
                    className={`rounded-full border px-3 py-1 text-[13px] ${
                      visibility === v
                        ? "border-accent bg-soft-2 text-accent"
                        : "border-line text-ink-3 hover:border-line-strong"
                    }`}
                  >
                    {VISIBILITY_LABEL[v]}
                  </button>
                ))}
              </div>
            </div>

            <label className="block">
              <span className="block text-[13px] text-ink-3">
                {t("capacityHint")}
              </span>
              <input
                type="number"
                min={1}
                value={capacity}
                onChange={(e) => setCapacity(e.target.value)}
                className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
              />
            </label>

            <label className="block">
              <span className="block text-[13px] text-ink-3">
                {t("deadlineHint")}
              </span>
              <input
                type="datetime-local"
                value={deadline}
                onChange={(e) => setDeadline(e.target.value)}
                className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
              />
            </label>

            {error ? <p className="text-[13px] text-ink-3">{error}</p> : null}

            <button
              type="button"
              disabled={busy || title.trim() === ""}
              onClick={() => void submit()}
              className="rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
            >
              {busy ? t("creating") : t("create", { label })}
            </button>
          </div>
        </div>
      </div>
    </WorkspaceShell>
  );
}

/* ---------------- 内部 ---------------- */

import { useWorkspaceBySlug as useWorkspaceBySlugWrapper } from "@/lib/use-workspace-by-slug";
