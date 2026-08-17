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
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
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
import { translatePaymentError } from "@/lib/payment-errors";
import {
  parseSponsorshipTiers,
  submitEnrollment,
} from "@/lib/public-offerings";
import { useAuthed } from "@/lib/use-authed";

const TRANSITION_LABEL: Record<EventTransition, string> = {
  launch: "发布（开放报名）",
  close: "结束",
  cancel: "取消",
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
    return "保存失败：名额上限需大于等于 1。";
  }
  if (/cannot (launch|close|cancel) from status=/.test(raw)) {
    return "操作失败：状态已变更，请刷新后重试。";
  }
  if (/failed: status changed concurrently/.test(raw)) {
    return "操作失败：状态已被其他操作变更，请刷新后重试。";
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
          <span>截止 {formatDeadline(offering.registrationDeadline)}</span>
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
            error: e instanceof Error ? e.message : "加载失败",
          });
        }
      });

    return () => {
      cancelled = true;
    };
  }, [ws, kind]);

  const stale = ws ? state.wsId !== ws.id : false;
  const rows = stale ? null : state.rows;
  const loadError = stale ? null : state.error;
  const manage = ws ? canManageEvents(ws.myRoleNames) : false;
  const label = OFFERING_LABEL[kind];
  const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;

  return (
    <WorkspaceShell slug={slug}>
      <div className="ws-page-main__inner">
        <div className="ws-page-breadcrumb" aria-label="页面路径">
          <Link href="/">工作台</Link>
          <span>›</span>
          <Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
          <span>›</span>
          <strong>{label}</strong>
        </div>

        <header className="ws-page-heading">
          <div>
            <h1>{label}</h1>
            <p>浏览本工作台的{label}与报名信息</p>
          </div>
          {manage && ws ? (
            <Link
              href={`${base}/new`}
              className="inline-flex items-center gap-2 rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink"
            >
              <Icon name="plus" />
              新建{label}
            </Link>
          ) : null}
        </header>

        {loadError ? (
          <div className="rounded-large border border-line bg-card p-6 text-sm text-ink-3">
            加载失败
          </div>
        ) : wsLoading || rows === null ? (
          <div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
        ) : rows.length === 0 ? (
          <div className="rounded-large border border-dashed border-line bg-card p-10 text-center text-sm text-ink-3">
            还没有{label}。
            {manage
              ? `点击右上角「新建${label}」创建第一个。`
              : "等待 Owner 创建。"}
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
  pending: "待启动",
  running: "教研中",
  waiting: "教研中(等待产出)",
  succeeded: "已完成",
  failed: "失败",
  cancelled: "已取消",
  expired: "已过期",
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
  const {
    ws,
    readOnlyVisitor,
    loading: wsLoading,
  } = useWorkspaceBySlugWrapper(slug);
  const { userId } = useAuthed();
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
            error: "加载失败",
          });
        }
      });

    return () => {
      cancelled = true;
    };
  }, [id, kind]);

  // 我的既有报名（防重复报名；读策略仅本人可见）
  useEffect(() => {
    if (!id || !userId) return;
    let cancelled = false;

    fetchMyEnrollment(id, kind, userId)
      .then((enrollment) => {
        if (!cancelled)
          setEnrollState({ id, enrollment, status: "ok" });
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

  const stale = state.id !== id;
  const offering = stale ? null : state.row;

  // 收费目标：可售档位（R2 后端已过滤过期档）与所选档（R5 报名须选档）
  const priceTiers = parsePriceTiers(offering?.availablePriceTiers);
  const [tierId, setTierId] = useState<string | null>(null);
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
  }, [id, kind, manage]);
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
        setSaveMessage("已保存");
      } else {
        setSaveMessage(
          friendlyOfferingError(res.errors[0], "保存失败，请重试"),
        );
      }
    } catch (e: unknown) {
      setSaveMessage(
        friendlyOfferingError(
          e instanceof Error ? { message: e.message } : null,
          "保存失败，请重试",
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
        setSaveMessage("已保存");
      } else {
        setSaveMessage(
          friendlyOfferingError(res.errors[0], "保存失败，请重试"),
        );
      }
    } catch (e: unknown) {
      setSaveMessage(
        friendlyOfferingError(
          e instanceof Error ? { message: e.message } : null,
          "保存失败，请重试",
        ),
      );
    } finally {
      setSaveBusy(false);
    }
  }

  async function runTransition(t: EventTransition) {
    if (!offering) return;
    setBusyTransition(t);
    try {
      const res = await transitionOffering(offering.id, kind, t);
      if (res.result) {
        setState({
          id: offering.id,
          row: { ...offering, status: res.result.status },
          error: null,
        });
      } else {
        setSaveMessage(
          friendlyOfferingError(res.errors[0], "操作失败，请重试"),
        );
      }
    } catch (e: unknown) {
      setSaveMessage(
        friendlyOfferingError(
          e instanceof Error ? { message: e.message } : null,
          "操作失败，请重试",
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
      setSubmitState({ kind: "error", message: "请先选择价格档位" });
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
            message: "名额已保留，请在限定时间内完成支付",
            enrollmentId: res.result.id,
          });
        } else if (status === "pending") {
          setSubmitState({
            kind: "pending",
            message: "申请已提交，等待审批",
          });
        } else {
          setSubmitState({ kind: "confirmed", message: "报名成功" });
        }
      } else {
        setSubmitState({
          kind: "error",
          message: translatePaymentError(
            res.errors[0]?.message,
            "提交失败",
          ),
        });
      }
    } catch (e: unknown) {
      setSubmitState({
        kind: "error",
        message: translatePaymentError(
          e instanceof Error ? e.message : null,
          "提交失败",
        ),
      });
    } finally {
      setEnrollBusy(false);
    }
  }

  return (
    <WorkspaceShell slug={slug}>
      <div className="ws-page-main__inner">
        <div className="ws-page-breadcrumb" aria-label="页面路径">
          <Link href="/">工作台</Link>
          <span>›</span>
          <Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
          <span>›</span>
          <Link href={base}>{label}</Link>
          <span>›</span>
          <strong>{offering?.title ?? "详情"}</strong>
        </div>

        {loadError ? (
          <div className="rounded-large border border-line bg-card p-6 text-sm text-ink-3">
            加载失败
          </div>
        ) : offering === null && !stale ? (
          <div className="join-card text-center">
            <h1 className="text-lg font-medium">该{label}不可访问或不存在</h1>
            <p className="mt-2 text-sm text-ink-3">
              仅工作台内部可见，或已结束。请登录后从工作台内访问。
            </p>
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
                <h2 className="text-sm font-medium text-ink">基本信息</h2>
                <div className="mt-4 grid gap-4">
                  <Field label="报名策略">
                    {ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy]}
                  </Field>
                  <Field label="报名截止">
                    {formatDeadline(offering.registrationDeadline)}
                  </Field>
                  <Field label="名额">
                    {offering.capacity === null
                      ? `不限（已确认 ${offering.confirmedCount ?? 0}）`
                      : `${offering.confirmedCount ?? 0} / ${offering.capacity}`}
                  </Field>
                  {manage ? (
                    <Field label="待审批报名">
                      {pendingState.id !== id ||
                      pendingState.status === "loading"
                        ? "—"
                        : pendingState.status === "error"
                          ? "加载失败"
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
                  <h2 className="text-sm font-medium text-ink">教研</h2>
                  <dl className="mt-3 grid gap-2 text-sm">
                    <div className="flex items-center gap-2">
                      <dt className="text-ink-3">教研 run 状态:</dt>
                      <dd
                        className="text-ink"
                        data-testid="research-run-status"
                      >
                        {offering.workflowRun?.status
                          ? (RESEARCH_RUN_STATUS_LABEL[
                              offering.workflowRun.status
                            ] ?? offering.workflowRun.status)
                          : offering.workflowRunId
                            ? "已关联"
                            : "未实例化"}
                      </dd>
                    </div>
                    <div className="flex items-center gap-2">
                      <dt className="text-ink-3">课程内容完成度:</dt>
                      <dd
                        className="text-ink"
                        data-testid="research-content-status"
                      >
                        {offering.workflowRun?.status === "succeeded"
                          ? "issue 卡已提交"
                          : "待教研产出"}
                      </dd>
                    </div>
                  </dl>
                </div>
              ) : null}

              {manage && activeDraft ? (
                <div className="rounded-large border border-line bg-card p-6">
                  <h2 className="text-sm font-medium text-ink">编辑元数据</h2>

                  <div className="mt-4 grid gap-3">
                    <label className="block">
                      <span className="block text-[13px] text-ink-3">标题</span>
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
                        报名策略
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
                        名额上限（留空 = 不限）
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
                        报名截止（留空 = 不设截止）
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
                          教研需求（自由文本，教研 Agent 起草 issue 卡的输入）
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
                          placeholder="目标学员、课时、想覆盖的主题…"
                        />
                      </label>
                    ) : null}

                    <button
                      type="button"
                      disabled={saveBusy || activeDraft.title.trim() === ""}
                      onClick={() => void saveMeta()}
                      className="mt-1 rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
                    >
                      {saveBusy ? "保存中…" : "保存元数据"}
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
                <h2 className="text-sm font-medium text-ink">报名</h2>
                <div className="mt-3 text-sm">
                  {submitState.kind === "confirmed" ||
                  submitState.kind === "pending" ||
                  submitState.kind === "payment_pending" ? (
                    <div role="status" className="grid gap-2">
                      <p className="text-ink">
                        {submitState.kind === "confirmed"
                          ? "✓ 报名成功"
                          : submitState.kind === "payment_pending"
                            ? "⏳ 待支付"
                            : "✓ 申请已提交"}
                        {submitState.message ? `（${submitState.message}）` : ""}
                      </p>
                      {submitState.kind === "payment_pending" && submitState.enrollmentId ? (
                        <Link
                          href={`/orders/new?enrollmentId=${submitState.enrollmentId}`}
                          className="justify-self-start rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line"
                        >
                          去支付
                        </Link>
                      ) : null}
                    </div>
                  ) : enrollState.enrollment?.status === "payment_pending" ? (
                    <div
                      className="grid gap-2"
                      role="status"
                      data-testid="enrollment-pending-card"
                    >
                      <p className="text-ink">
                        ⏳ 名额已保留，请在限定时间内完成支付
                      </p>
                      <Link
                        href={`/orders/new?enrollmentId=${enrollState.enrollment.id}`}
                        data-testid="enrollment-pending-pay"
                        className="justify-self-start rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line"
                      >
                        去支付
                      </Link>
                    </div>
                  ) : enrollState.enrollment?.status === "pending" ? (
                    <p className="text-[13px] text-ink-3">
                      你已报名该{label}，申请审批中，通过后确认名额。
                    </p>
                  ) : enrollState.enrollment ? (
                    <p className="text-[13px] text-ink-3">
                      你已报名该{label}。
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
                          提交后需 Owner/Admin 审批，通过后确认名额。
                        </p>
                      ) : null}
                      {offering.pricingEnabled ? (
                        <fieldset className="grid gap-2" data-testid="price-tier-picker">
                          <legend className="text-[13px] text-ink-3">选择价格档位</legend>
                          {priceTiers.length === 0 ? (
                            <p className="text-[13px] text-ink-3">
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
                                <span className="font-medium">¥{formatAmount(tier.amountCents)}</span>
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
                        {enrollBusy ? "提交中…" : "报名"}
                      </button>
                    </div>
                  )}
                </div>
              </div>
            ) : null}

            {manage ? (
              <div className="mt-4 rounded-large border border-line bg-card p-6">
                <h2 className="text-sm font-medium text-ink">生命周期</h2>

                <div className="mt-3">
                  <span className="block text-[13px] text-ink-3">
                    可见性（可随时切换，公开页立即生效）
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
                  {transitions.map((t) =>
                    confirmingTransition === t ? (
                      <div
                        key={t}
                        className="w-full rounded-large border border-line bg-soft-2 p-3"
                      >
                        <p
                          className="text-[13px] text-ink-3"
                          aria-live="polite"
                        >
                          {t === "close"
                            ? `确认结束该${label}？报名入口将关闭，终态不可恢复。`
                            : `确认取消该${label}？报名入口将关闭，终态不可恢复。`}
                        </p>
                        <div className="mt-2 flex gap-2">
                          <button
                            type="button"
                            disabled={busyTransition !== null}
                            onClick={() => void runTransition(t)}
                            className="rounded-large border border-danger px-3 py-1.5 text-[13px] text-danger disabled:opacity-50"
                          >
                            {busyTransition === t
                              ? "处理中…"
                              : `确认${TRANSITION_LABEL[t]}`}
                          </button>
                          <button
                            type="button"
                            disabled={busyTransition !== null}
                            onClick={() => setConfirmingTransition(null)}
                            className="rounded-large border border-line px-3 py-1.5 text-[13px] text-ink-3 disabled:opacity-50"
                          >
                            返回
                          </button>
                        </div>
                      </div>
                    ) : (
                      <button
                        key={t}
                        type="button"
                        disabled={busyTransition !== null}
                        onClick={() => {
                          if (t === "close" || t === "cancel") {
                            setConfirmingTransition(t);
                          } else {
                            void runTransition(t);
                          }
                        }}
                        className="rounded-large border border-line bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line-strong disabled:opacity-50"
                      >
                        {busyTransition === t ? "处理中…" : TRANSITION_LABEL[t]}
                      </button>
                    ),
                  )}
                  {transitions.length === 0 ? (
                    <span className="text-[13px] text-ink-3">
                      终态{label}无可执行的生命周期操作（v1 终态不可逆）。
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
                      setSaveMessage(res.errors[0]?.message ?? "保存失败");
                      return false;
                    } catch (e: unknown) {
                      setSaveMessage(
                        e instanceof Error ? e.message : "保存失败",
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
        setError(res.errors[0]?.message ?? "创建失败");
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "创建失败");
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
            仅 Owner/Admin 可创建{label}。
            <Link href={base} className="ml-2 text-accent">
              返回{label}列表
            </Link>
          </div>
        </div>
      </WorkspaceShell>
    );
  }

  return (
    <WorkspaceShell slug={slug}>
      <div className="ws-page-main__inner">
        <div className="ws-page-breadcrumb" aria-label="页面路径">
          <Link href="/">工作台</Link>
          <span>›</span>
          <Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
          <span>›</span>
          <Link href={base}>{label}</Link>
          <span>›</span>
          <strong>新建{label}</strong>
        </div>

        <header className="ws-page-heading">
          <div>
            <h1>新建{label}</h1>
            <p>创建后为草稿，发布后进入开放报名</p>
          </div>
        </header>

        <div className="max-w-xl rounded-large border border-line bg-card p-6">
          <div className="grid gap-4">
            <label className="block">
              <span className="block text-[13px] text-ink-3">标题（必填）</span>
              <input
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
              />
            </label>

            <label className="block">
              <span className="block text-[13px] text-ink-3">报名策略</span>
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
              <span className="block text-[13px] text-ink-3">可见性</span>
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
                名额上限（留空 = 不限）
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
                报名截止（留空 = 不设截止）
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
              {busy ? "创建中…" : `创建${label}`}
            </button>
          </div>
        </div>
      </div>
    </WorkspaceShell>
  );
}

/* ---------------- 内部 ---------------- */

import { useWorkspaceBySlug as useWorkspaceBySlugWrapper } from "@/lib/use-workspace-by-slug";
