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

import { Link } from "@/i18n/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";
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
  VenueInfo,
  Visibility,
} from "@/lib/graphql/events";
import {
  ENROLLMENT_POLICIES,
  ENROLLMENT_POLICY_LABEL,
  OFFERING_LABEL,
  VISIBILITIES,
  VISIBILITY_LABEL,
} from "@/lib/graphql/events";
import TierEditor, { fromDraft, toDraft, type TierDraft } from "@/components/tier-editor";
import OfferingPaymentsPanel from "@/components/offering-payments-panel";
import WorkspaceShell from "@/components/workspace-shell";
import { client } from "@/lib/apollo-client";
import { WORKSPACE_ORDERS, WORKSPACE_PAYMENT_STATS } from "@/lib/graphql/orders";
import EventStatusTag from "@/components/event-status-tag";
import SpeakerInvitationPanel from "@/components/speaker-invitation-panel";
import InviteBatchPanel from "@/components/invite-batch-panel";
import { Icon } from "@/components/icons";
import SponsorshipManagement from "@/components/sponsorship-management";
import { formatAmount, parsePaymentStats, parsePriceTiers } from "@/lib/payment";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import {
  parseSponsorshipTiers,
  parseVenue,
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
  // KTD6：ends_at 须严格晚于 starts_at（message-only，无 domain_error_code）
  if (/ends_at must be after starts_at/.test(raw)) {
    return "scheduleOrderError";
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

/* ---------------- 时间与 venue 录入（U5/R14，KTD5/KTD6） ---------------- */

/** venue 四键空草稿（全空 = 线上/未定，提交时由 lib 组装为 null） */
const EMPTY_VENUE: VenueInfo = { country: "", province: "", city: "", district: "" };

/** venue all-or-none：任一填写但四键未齐（trim 后）→ true，表单就地拦截不提交 */
function venueDraftIncomplete(venue: VenueInfo): boolean {
  const filled = Object.values(venue).filter((v) => v.trim() !== "").length;
  return filled > 0 && filled < 4;
}

/** 开始/结束时间录入（datetime-local，留空 = 未定；end>start 由后端复验，KTD6） */
function ScheduleFields({
  startsAt,
  endsAt,
  onStartsAtChange,
  onEndsAtChange,
}: {
  startsAt: string;
  endsAt: string;
  onStartsAtChange: (value: string) => void;
  onEndsAtChange: (value: string) => void;
}) {
  const t = useTranslations("offerings");
  return (
    <>
      <label className="block">
        <span className="block text-[13px] text-ink-3">{t("startsAtHint")}</span>
        <input
          type="datetime-local"
          value={startsAt}
          onChange={(e) => onStartsAtChange(e.target.value)}
          className="ld-focus-ring mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
        />
      </label>
      <label className="block">
        <span className="block text-[13px] text-ink-3">{t("endsAtHint")}</span>
        <input
          type="datetime-local"
          value={endsAt}
          onChange={(e) => onEndsAtChange(e.target.value)}
          className="ld-focus-ring mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
        />
      </label>
    </>
  );
}

const VENUE_FIELD_LABEL: Record<keyof VenueInfo, string> = {
  country: "venueCountry",
  province: "venueProvince",
  city: "venueCity",
  district: "venueDistrict",
};

/** 结构化 venue 四键录入（KTD5；仅 event；all-or-none 提交前拦截） */
function VenueFields({
  value,
  onChange,
}: {
  value: VenueInfo;
  onChange: (value: VenueInfo) => void;
}) {
  const t = useTranslations("offerings");
  return (
    <fieldset className="grid gap-3">
      <legend className="text-[13px] text-ink-3">{t("venueSection")}</legend>
      {(Object.keys(VENUE_FIELD_LABEL) as (keyof VenueInfo)[]).map((key) => (
        <label className="block" key={key}>
          <span className="block text-[13px] text-ink-3">
            {t(VENUE_FIELD_LABEL[key])}
          </span>
          <input
            value={value[key]}
            onChange={(e) => onChange({ ...value, [key]: e.target.value })}
            className="ld-focus-ring mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
          />
        </label>
      ))}
    </fieldset>
  );
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
  const tCommon = useTranslations("common");
  const labelsT = useTranslations();
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
          <span>{labelsT(ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy])}</span>
          <span>·</span>
          <span>{labelsT(VISIBILITY_LABEL[offering.visibility])}</span>
          <span>·</span>
          <span>
            {t("deadlineLabel", {
              deadline: formatDeadline(
                offering.registrationDeadline,
                tCommon("noDeadline"),
              ),
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
  const labelsT = useTranslations();
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
  const manage = ws ? canManageEvents(ws.myAbilities) : false;
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
          <strong>{labelsT(label)}</strong>
        </div>

        <header className="ws-page-heading">
          <div>
            <h1>{labelsT(label)}</h1>
            <p>{t("subtitle", { label: labelsT(label) })}</p>
          </div>
          {manage && ws ? (
            <Link
              href={`${base}/new`}
              className="inline-flex items-center gap-2 rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink"
            >
              <Icon name="plus" />
              {t("createNew", { label: labelsT(label) })}
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
            {t("empty", { label: labelsT(label) })}
            {manage ? t("emptyCreateHint", { label: labelsT(label) }) : t("emptyWaitHint")}
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
  /** 开始/结束时间（datetime-local input 值，"" = 未定；R1，course 语义为开课/结课） */
  startsAt: string;
  endsAt: string;
  /** venue 四键草稿（仅 event 渲染与下发；全空 = 线上/未定） */
  venue: VenueInfo;
  /** 教研需求自由文本(U8/R12,仅 course;原文透传 curriculum_requirements) */
  curriculumRequirements: string;
  /** 收费设置（U6/R2）：开关 + 档位草稿（编辑面就地修改） */
  pricingEnabled: boolean;
  tierDrafts: TierDraft[];
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
  const labelsT = useTranslations();
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
  // U8 守卫：关收费/取消披露的订单计数 + 已售档 id 集合（懒查询，R9/R10/R11）
  const [guardCounts, setGuardCounts] = useState<{
    status: "idle" | "loading" | "ready";
    paidCount: number;
    paidCents: number;
    pendingCount: number;
    soldTierIds: string[];
  }>({ status: "idle", paidCount: 0, paidCents: 0, pendingCount: 0, soldTierIds: [] });
  // saveMeta 守卫阶段：关收费确认 / 开收费披露（AE1/AE8 前端半）
  const [pricingGuard, setPricingGuard] = useState<
    "disable-confirm" | "enable-confirm" | null
  >(null);
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
  const manage = ws ? canManageEvents(ws.myAbilities) : false;

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
            startsAt: toLocalInput(offering.startsAt ?? null),
            endsAt: toLocalInput(offering.endsAt ?? null),
            venue: parseVenue(offering.venue) ?? { ...EMPTY_VENUE },
            curriculumRequirements: parseResearchText(
              offering.curriculumRequirements,
            ),
            // KTD9：读全量 priceTiers（含过期档），防止保存静默丢弃过期档
            pricingEnabled: offering.pricingEnabled === true,
            tierDrafts: toDraft(offering.priceTiers),
          }
        : null;

  // U8/R10：删除或改价命中已售档（快照语义保证已付订单金额不受影响，警告放行）
  const soldTierTouched: string[] = useMemo(() => {
    if (!offering || !activeDraft || guardCounts.status !== "ready") return [];
    const originals = toDraft(offering.priceTiers);
    const deleted = guardCounts.soldTierIds.filter(
      (tid) => !activeDraft.tierDrafts.some((d) => d.id === tid),
    );
    const repriced = activeDraft.tierDrafts
      .filter((d) => {
        if (!guardCounts.soldTierIds.includes(d.id)) return false;
        const orig = originals.find((o) => o.id === d.id);
        if (!orig) return false;
        return fromDraft(orig)?.amount_cents !== fromDraft(d)?.amount_cents;
      })
      .map((d) => d.id);
    return [...deleted, ...repriced];
  }, [offering, activeDraft, guardCounts]);

  // U8：编辑面 + 收费开启时取一次守卫数据（已售档集合；守卫数字在确认时点再刷新）
  useEffect(() => {
    if (manage && offering?.pricingEnabled === true && guardCounts.status === "idle") {
      void loadGuardCounts();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [manage, offering?.id, offering?.pricingEnabled]);

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

  // 取消披露 N/¥X、已售档 id 集合同源；快照时点容忍执行窗口内变化。
  // review F6：N/¥X 走服务端 stats 聚合（authoritative，不裁剪于首页 50 行、
  // 绕过 Apollo cache-first）；已售档 id 集仍需订单行（仅 paid、no-store）。
  async function loadGuardCounts() {
    if (!offering) return;
    setGuardCounts((s) => ({ ...s, status: "loading" }));
    try {
      const key = kind === "event" ? "eventId" : "courseId";
      const [statsRes, paidRes, pendingRes] = await Promise.all([
        client.query({
          query: WORKSPACE_PAYMENT_STATS,
          variables: {
            workspaceId: offering.workspaceId ?? ws?.id ?? "",
            [key]: offering.id,
          },
          fetchPolicy: "network-only",
        }),
        client.query({
          query: WORKSPACE_ORDERS,
          variables: {
            workspaceId: offering.workspaceId ?? ws?.id ?? "",
            filter: { [key]: { eq: offering.id }, status: { eq: "paid" } },
          },
          fetchPolicy: "network-only",
        }),
        client.query({
          query: WORKSPACE_ORDERS,
          variables: {
            workspaceId: offering.workspaceId ?? ws?.id ?? "",
            filter: { [key]: { eq: offering.id }, status: { eq: "pending" } },
            first: 1,
          },
          fetchPolicy: "network-only",
        }),
      ]);

      const stats = parsePaymentStats(statsRes.data?.workspacePaymentStats);
      const paidRows = (paidRes.data?.workspaceOrders?.results ?? []) as Array<{
        tierId?: string | null;
      }>;

      setGuardCounts({
        status: "ready",
        // paid/pending 笔数 = 服务端 count（权威总数，不裁剪于页大小）
        paidCount: paidRes.data?.workspaceOrders?.count ?? paidRows.length,
        paidCents: stats?.collectedCents ?? 0,
        pendingCount: pendingRes.data?.workspaceOrders?.count ?? 0,
        soldTierIds: paidRows
          .map((o) => o.tierId)
          .filter((x): x is string => typeof x === "string"),
      });
    } catch {
      setGuardCounts((s) => ({ ...s, status: "idle" }));
    }
  }

  async function saveMeta() {
    if (!offering || !activeDraft) return;
    // venue all-or-none：任一填写则四键须齐全，否则就地拦截不提交（KTD5）
    if (kind === "event" && venueDraftIncomplete(activeDraft.venue)) {
      setSaveMessage(t("venueIncomplete"));
      return;
    }
    // U8 资金守卫（R9/R16，KD2）：关收费 → 明示影响后确认；开收费且有
    // 待审批 → 披露后确认；其余直接保存。守卫数字为确认时点快照。
    const disabling =
      offering.pricingEnabled === true && activeDraft.pricingEnabled === false;
    const enabling =
      offering.pricingEnabled !== true && activeDraft.pricingEnabled === true;
    const pendingApprovals =
      pendingState.id === id && pendingState.status === "ok"
        ? pendingState.value
        : 0;

    if (disabling) {
      void loadGuardCounts();
      setPricingGuard("disable-confirm");
      return;
    }
    if (enabling && pendingApprovals > 0) {
      setPricingGuard("enable-confirm");
      return;
    }
    await performSaveMeta();
  }

  async function performSaveMeta() {
    if (!offering || !activeDraft) return;
    // review F11：校验前置（setSaveBusy 之前）——无效档位不再把保存按钮
    // 永久卡死；混合有效/无效行拒绝整次提交（不静默丢弃无效行）
    const validTiers =
      activeDraft.tierDrafts.map(fromDraft).filter((x) => x !== null);
    if (
      activeDraft.tierDrafts.length > 0 &&
      validTiers.length !== activeDraft.tierDrafts.length
    ) {
      setSaveMessage(t("pricingTierInvalid"));
      return;
    }
    if (activeDraft.pricingEnabled && validTiers.length === 0) {
      setSaveMessage(t("pricingTierRequired"));
      return;
    }

    // review F7：定价脏检查——仅当开关或档位相对服务端快照变化时下发定价键，
    // 普通 metadata 保存不再整段重发定价快照（消除陈旧管理员把已关闭的收费
    // 连旧档位一起恢复的除改窗口；服务端值仍是唯一真源）
    const pricingDirty =
      offering.pricingEnabled !== activeDraft.pricingEnabled ||
      JSON.stringify(toDraft(offering.priceTiers)) !==
        JSON.stringify(activeDraft.tierDrafts);

    setSaveBusy(true);
    setSaveMessage(null);
    try {
      const res = await updateOffering(offering.id, kind, {
        title: activeDraft.title,
        enrollmentPolicy: activeDraft.enrollmentPolicy,
        capacity:
          activeDraft.capacity === "" ? null : Number(activeDraft.capacity),
        registrationDeadline: fromLocalInput(activeDraft.deadline),
        startsAt: fromLocalInput(activeDraft.startsAt),
        endsAt: fromLocalInput(activeDraft.endsAt),
        ...(kind === "course"
          ? {
              curriculumRequirements: buildResearchJson(
                activeDraft.curriculumRequirements,
              ),
            }
          : { venue: activeDraft.venue }),
        ...(pricingDirty
          ? {
              pricingEnabled: activeDraft.pricingEnabled,
              priceTiers: validTiers.map((tier) => JSON.stringify(tier)),
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
            startsAt: res.result.startsAt ?? null,
            endsAt: res.result.endsAt ?? null,
            ...(kind === "event" ? { venue: res.result.venue ?? null } : {}),
            ...(res.result.pricingEnabled !== undefined
              ? { pricingEnabled: res.result.pricingEnabled }
              : {}),
            ...(res.result.priceTiers !== undefined
              ? { priceTiers: res.result.priceTiers }
              : {}),
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
          <Link href={base}>{labelsT(label)}</Link>
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
              {t("notAccessible", { label: labelsT(label) })}
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
                    {labelsT(VISIBILITY_LABEL[offering.visibility])}
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
                    {labelsT(ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy])}
                  </Field>
                  <Field label={t("fieldDeadline")}>
                    {formatDeadline(
                      offering.registrationDeadline,
                      tCommon("noDeadline"),
                    )}
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
                  {manage ? (
                    <Field label={t("fieldPricing")}>
                      {offering.pricingEnabled
                        ? t("pricingOn", {
                                overview: parsePriceTiers(offering.availablePriceTiers)
                                  .map(
                                    (tier) =>
                                      `${tier.name} ¥${formatAmount(tier.amountCents)}`,
                                  )
                                  .join(" / "),
                              })
                        : t("pricingFree")}
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
                            {labelsT(ENROLLMENT_POLICY_LABEL[p])}
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

                    {/* R18（ADR-0009 U7）：目标容量 < 当前已占席数仅警告不拦截——
                        后端放行编辑，超员部分由账本 CAS 拒新单 + 自然释放收敛（AE4） */}
                    {activeDraft.capacity !== "" &&
                      Number(activeDraft.capacity) <
                        (offering?.confirmedCount ?? 0) && (
                        <p
                          role="alert"
                          className="text-[13px] text-amber-200"
                          data-testid="capacity-below-occupied-warning"
                        >
                          {t("capacityBelowOccupied", {
                            confirmed: offering?.confirmedCount ?? 0,
                          })}
                        </p>
                      )}

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

                    <ScheduleFields
                      startsAt={activeDraft.startsAt}
                      endsAt={activeDraft.endsAt}
                      onStartsAtChange={(v) =>
                        setMetaDraft({ ...activeDraft, startsAt: v })
                      }
                      onEndsAtChange={(v) =>
                        setMetaDraft({ ...activeDraft, endsAt: v })
                      }
                    />

                    {kind === "event" ? (
                      <VenueFields
                        value={activeDraft.venue}
                        onChange={(v) =>
                          setMetaDraft({ ...activeDraft, venue: v })
                        }
                      />
                    ) : null}

                    {kind === "course" ? (
                      <label className="block">
                        <span className="block text-[13px] text-ink-3">
                          {t("researchNeed")}
                        </span>
                        <textarea
                          data-testid="research-requirements-input"
                          rows={4}
                          value={activeDraft.curriculumRequirements}
                          onChange={(e) =>
                            setMetaDraft({
                              ...activeDraft,
                              curriculumRequirements: e.target.value,
                            })
                          }
                          className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
                          placeholder={t("researchPlaceholder")}
                        />
                      </label>
                    ) : null}

                    {/* 收费设置（U6/R2）：开关 + 档位就地修改（关收费守卫弹窗 U8 接入） */}
                    <div className="grid gap-2" data-testid="pricing-edit-section">
                      <label className="flex items-center gap-2 text-sm text-ink-2">
                        <input
                          type="checkbox"
                          checked={activeDraft.pricingEnabled}
                          onChange={(e) =>
                            setMetaDraft({
                              ...activeDraft,
                              pricingEnabled: e.target.checked,
                            })
                          }
                          data-testid="pricing-toggle"
                        />
                        {t("pricingEnable")}
                      </label>
                      {activeDraft.pricingEnabled && (
                        <TierEditor
                          drafts={activeDraft.tierDrafts}
                          onChange={(tierDrafts) =>
                            setMetaDraft({ ...activeDraft, tierDrafts })
                          }
                          manage
                        />
                      )}
                      {soldTierTouched.length > 0 && (
                        <p
                          role="alert"
                          className="text-[13px] text-amber-200"
                          data-testid="sold-tier-warning"
                        >
                          {t("guardSoldTier")}
                        </p>
                      )}
                    </div>

                    {/* U8 资金守卫确认（R9/R16）：关收费明示影响、开收费披露待审批；确认后执行 */}
                    {pricingGuard === "disable-confirm" ? (
                      <div
                        className="rounded-large border border-amber-400/30 bg-amber-500/10 p-3"
                        role="group"
                        aria-label={t("guardDisableTitle")}
                        data-testid="pricing-disable-guard"
                      >
                        <p className="text-sm text-amber-200">
                          {guardCounts.status === "ready"
                            ? t("guardDisableBody", {
                                paid: guardCounts.paidCount,
                                pending: guardCounts.pendingCount,
                              })
                            : t("guardDisableLoading")}
                        </p>
                        <div className="mt-3 flex flex-wrap gap-2">
                          <button
                            type="button"
                            className="join-button join-button--primary"
                            disabled={guardCounts.status !== "ready" || saveBusy}
                            onClick={() => {
                              setPricingGuard(null);
                              void performSaveMeta();
                            }}
                            data-testid="pricing-guard-confirm"
                          >
                            {t("guardConfirm")}
                          </button>
                          <button
                            type="button"
                            className="join-button"
                            disabled={saveBusy}
                            onClick={() => setPricingGuard(null)}
                            data-testid="pricing-guard-cancel"
                          >
                            {t("guardCancel")}
                          </button>
                        </div>
                      </div>
                    ) : null}
                    {pricingGuard === "enable-confirm" ? (
                      <div
                        className="rounded-large border border-amber-400/30 bg-amber-500/10 p-3"
                        role="group"
                        aria-label={t("guardEnableTitle")}
                        data-testid="pricing-enable-guard"
                      >
                        <p className="text-sm text-amber-200">
                          {t("guardEnableBody", {
                            pending: pendingState.id === id ? pendingState.value : 0,
                          })}
                        </p>
                        <div className="mt-3 flex flex-wrap gap-2">
                          <button
                            type="button"
                            className="join-button join-button--primary"
                            disabled={saveBusy}
                            onClick={() => {
                              setPricingGuard(null);
                              void performSaveMeta();
                            }}
                            data-testid="pricing-guard-confirm"
                          >
                            {t("guardConfirm")}
                          </button>
                          <button
                            type="button"
                            className="join-button"
                            disabled={saveBusy}
                            onClick={() => setPricingGuard(null)}
                            data-testid="pricing-guard-cancel"
                          >
                            {t("guardCancel")}
                          </button>
                        </div>
                      </div>
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
                      {t("pendingApproval", { label: labelsT(label) })}
                    </p>
                  ) : enrollState.enrollment ? (
                    <p className="text-[13px] text-ink-3">
                      {t("enrolled", { label: labelsT(label) })}
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
                        {labelsT(VISIBILITY_LABEL[v])}
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
                            ? t("transitionConfirmClose", { label: labelsT(label) })
                            : t("transitionConfirmCancel", { label: labelsT(label) })}
                        </p>
                        {/* U8 披露（R11/R17）：收费活动的取消/结束明示资金影响；免费活动文案不变 */}
                        {tr === "cancel" &&
                        offering.pricingEnabled === true &&
                        guardCounts.status === "ready" ? (
                          <p
                            className="mt-1 text-[13px] text-amber-200"
                            data-testid="cancel-refund-disclosure"
                          >
                            {t("guardCancelRefund", {
                              count: guardCounts.paidCount,
                              amount: formatAmount(guardCounts.paidCents),
                            })}
                          </p>
                        ) : null}
                        {tr === "cancel" &&
                        offering.pricingEnabled === true &&
                        guardCounts.status !== "ready" ? (
                          <p
                            className="mt-1 text-[13px] text-ink-3"
                            data-testid="cancel-refund-loading"
                          >
                            {guardCounts.status === "loading"
                              ? t("guardDisableLoading")
                              : t("guardCountsFailed")}
                          </p>
                        ) : null}
                        {tr === "close" && offering.pricingEnabled === true ? (
                          <p
                            className="mt-1 text-[13px] text-ink-3"
                            data-testid="close-pending-disclosure"
                          >
                            {t("guardClosePending")}
                          </p>
                        ) : null}
                        <div className="mt-2 flex gap-2">
                          <button
                            type="button"
                            disabled={
                              busyTransition !== null ||
                              (tr === "cancel" &&
                                offering.pricingEnabled === true &&
                                guardCounts.status !== "ready")
                            }
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
                            // R11：取消收费活动明示自动退款笔数与总金额
                            if (tr === "cancel" && offering.pricingEnabled === true) {
                              void loadGuardCounts();
                            }
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
                      {t("terminalNote", { label: labelsT(label) })}
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

            {/* organizer-payment U7/R5-R7：本活动经营面（四数统计 + 订单 + 行内操作） */}
            <div className="mt-4">
              <OfferingPaymentsPanel
                workspaceId={offering.workspaceId ?? ws?.id ?? ""}
                offeringId={offering.id}
                kind={kind}
                manage={manage}
                pricingEnabled={offering.pricingEnabled === true}
              />
            </div>
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
  const labelsT = useTranslations();
  const router = useRouter();
  const { ws, loading: wsLoading } = useWorkspaceBySlugWrapper(slug);

  const [title, setTitle] = useState("");
  const [enrollmentPolicy, setEnrollmentPolicy] =
    useState<EnrollmentPolicy>("open");
  const [visibility, setVisibility] = useState<Visibility>("public");
  const [capacity, setCapacity] = useState("");
  const [deadline, setDeadline] = useState("");
  // 开始/结束时间（datetime-local 原值；R1）与 venue 四键草稿（仅 event，KTD5）
  const [startsAt, setStartsAt] = useState("");
  const [endsAt, setEndsAt] = useState("");
  const [venue, setVenue] = useState<VenueInfo>({ ...EMPTY_VENUE });
  // 收费设置（U6/R1）：默认免费收起（AE4 免费路径零额外操作）；开启时
  // 至少一档的客户端校验对齐后端 PriceTiersValidation。
  const [pricingEnabled, setPricingEnabled] = useState(false);
  const [tierDrafts, setTierDrafts] = useState<TierDraft[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const manage = ws ? canManageEvents(ws.myAbilities) : false;
  const label = OFFERING_LABEL[kind];
  const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;
  async function submit() {
    if (!ws) return;
    // venue all-or-none：任一填写则四键须齐全，否则就地拦截不提交（KTD5）
    if (kind === "event" && venueDraftIncomplete(venue)) {
      setError(t("venueIncomplete"));
      return;
    }
    // 收费开启：至少一档有效（PriceTiersValidation 前端先拦，后端兜底）
    const validTiers = tierDrafts.map(fromDraft).filter((x) => x !== null);
    if (pricingEnabled && validTiers.length === 0) {
      setError(t("pricingTierRequired"));
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const res = await createOffering(ws.id, kind, {
        title: title.trim(),
        enrollmentPolicy,
        visibility,
        capacity: capacity === "" ? null : Number(capacity),
        registrationDeadline: fromLocalInput(deadline),
        startsAt: fromLocalInput(startsAt),
        endsAt: fromLocalInput(endsAt),
        ...(kind === "event" ? { venue } : {}),
        ...(pricingEnabled
          ? {
              pricingEnabled,
              priceTiers: validTiers.map((tier) => JSON.stringify(tier)),
            }
          : {}),
      });
      if (res.result) {
        router.push(`${base}/${res.result.id}`);
      } else {
        setError(t(friendlyOfferingError(res.errors[0], "createFailed")));
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
            {t("ownerOnly", { label: labelsT(label) })}
            <Link href={base} className="ml-2 text-accent">
              {t("backToList", { label: labelsT(label) })}
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
          <Link href={base}>{labelsT(label)}</Link>
          <span>›</span>
          <strong>{t("createTitle", { label: labelsT(label) })}</strong>
        </div>

        <header className="ws-page-heading">
          <div>
            <h1>{t("createTitle", { label: labelsT(label) })}</h1>
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
                    {labelsT(ENROLLMENT_POLICY_LABEL[p])}
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
                    {labelsT(VISIBILITY_LABEL[v])}
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

            <ScheduleFields
              startsAt={startsAt}
              endsAt={endsAt}
              onStartsAtChange={setStartsAt}
              onEndsAtChange={setEndsAt}
            />

            {kind === "event" ? (
              <VenueFields value={venue} onChange={setVenue} />
            ) : null}

            {/* 收费设置（U6/R1）：默认免费收起（<details> 折叠），开启后展开档位编辑 */}
            <details
              className="rounded-large border border-line bg-soft-2/40 p-4"
              data-testid="pricing-section"
            >
              <summary className="cursor-pointer text-sm font-medium text-ink">
                {t("pricingSectionTitle")}
              </summary>
              <div className="mt-3 grid gap-3">
                <p className="text-[13px] text-ink-3">{t("pricingSectionHint")}</p>
                <label className="flex items-center gap-2 text-sm text-ink-2">
                  <input
                    type="checkbox"
                    checked={pricingEnabled}
                    onChange={(e) => setPricingEnabled(e.target.checked)}
                    data-testid="pricing-toggle"
                  />
                  {t("pricingEnable")}
                </label>
                {pricingEnabled && (
                  <TierEditor drafts={tierDrafts} onChange={setTierDrafts} manage />
                )}
              </div>
            </details>

            {error ? <p className="text-[13px] text-ink-3">{error}</p> : null}

            <button
              type="button"
              disabled={busy || title.trim() === ""}
              onClick={() => void submit()}
              className="rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
            >
              {busy ? t("creating") : t("create", { label: labelsT(label) })}
            </button>
          </div>
        </div>
      </div>
    </WorkspaceShell>
  );
}

/* ---------------- 内部 ---------------- */

import { useWorkspaceBySlug as useWorkspaceBySlugWrapper } from "@/lib/use-workspace-by-slug";
