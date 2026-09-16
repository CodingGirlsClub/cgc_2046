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
import { useLocale, useTranslations } from "next-intl";
import {
  allowedTransitions,
  canManageEvents,
  createOffering,
  fetchMyActiveEnrollments,
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
import { TEACHING_ROLE_NAMES } from "@/lib/graphql/workspace";
import type { ActiveEnrollmentRow } from "@/lib/graphql/participations";

import TierEditor, { fromDraft, toDraft, type TierDraft } from "@/components/tier-editor";
import OfferingPaymentsPanel from "@/components/offering-payments-panel";
import EventModeratorsCard from "@/components/event-moderators-card";
import { fetchEventModerators } from "@/lib/graphql/moderators";
import WorkspaceShell from "@/components/workspace-shell";
import { client } from "@/lib/apollo-client";
import { WORKSPACE_ORDERS, WORKSPACE_PAYMENT_STATS } from "@/lib/graphql/orders";
import EventStatusTag from "@/components/event-status-tag";
import SpeakerInvitationPanel from "@/components/speaker-invitation-panel";
import InviteBatchPanel from "@/components/invite-batch-panel";
import { Icon } from "@/components/icons";
import SponsorshipManagement from "@/components/sponsorship-management";
import { formatAmount, formatAmountShort, parsePaymentStats, parsePriceTiers } from "@/lib/payment";
import {
  COURSE_PAYMENT_MODES,
  PAYMENT_MODES,
  PAYMENT_MODE_LABEL,
  depositAmountDraft,
  depositAmountToCents,
  paymentModeOf,
  paymentSlotChanged,
  paymentSlotPayload,
  type PaymentMode,
} from "@/lib/payment-mode";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import {
  parseCompanionCourse,
  parseSponsorshipTiers,
  serializeSponsorshipTier,
  formatVenue,
  parseVenue,
  submitEnrollment,
} from "@/lib/public-offerings";
import { useAuthed } from "@/lib/use-authed";
import PaymentCheckoutDialog from "@/components/payment-checkout-dialog";
import AddToCalendar from "@/components/add-to-calendar";
import {
  fetchInitiativeMountPreview,
  fetchPublicInitiatives,
  type InitiativeRulePreview,
  type PublicInitiativeCard,
} from "@/lib/graphql/initiatives";

/** 列表行个人报名状态（只这三态会出现在行内；终态不显示） */
type MyEnrollmentStatus = "pending" | "payment_pending" | "confirmed";

const MY_ENROLLMENT_STATUS_LABEL: Record<MyEnrollmentStatus, string> = {
  pending: "myEnrollStatus.pending",
  payment_pending: "myEnrollStatus.payment_pending",
  confirmed: "myEnrollStatus.confirmed",
};

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
  // slug 撞全局唯一索引(#447 identity 化后的字段级错误)→ 可操作指引
  if (/already been taken/.test(raw)) {
    return "saveSlugTaken";
  }
  return fallback;
}

/**
 * #624 报名门槛草稿（min_age / min_participants）："" → null（清除）；
 * 非法（≤0 / 小数 / 非数）→ undefined（表单层拦截，后端 constraints min: 1 兜底）。
 */
function positiveIntOrNull(input: string): number | null | undefined {
  const trimmed = input.trim();
  if (trimmed === "") return null;
  const value = Number(trimmed);
  return Number.isInteger(value) && value >= 1 ? value : undefined;
}

/**
 * mutation 错误 → 展示文案：带稳定 code 的业务错误查 errors namespace 文案表
 * （#241 错误码契约，后端 PaymentModeValidation / 互斥 CHECK 等）；无 code 或
 * 未知 code 回落到既有关键词映射与兜底，不透传 GraphQL 原文。
 */
function offeringErrorText(
  error:
    | {
        message?: string | null;
        short_message?: string | null;
        code?: string | null;
      }
    | null
    | undefined,
  fallbackKey: string,
  t: (key: string) => string,
  translateCode: (code: string | null | undefined, fallback: string) => string,
): string {
  const known = error?.code ? translateCode(error.code, "") : "";
  return known !== "" ? known : t(friendlyOfferingError(error, fallbackKey));
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
          className="ui-input mt-1 w-full"
        />
      </label>
      <label className="block">
        <span className="block text-[13px] text-ink-3">{t("endsAtHint")}</span>
        <input
          type="datetime-local"
          value={endsAt}
          onChange={(e) => onEndsAtChange(e.target.value)}
          className="ui-input mt-1 w-full"
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
            className="ui-input mt-1 w-full"
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

/** #596 规则读面状态：unavailable = 未加载/无权/失败 → 降级为 Event 现值 + 通用提示 */
type InitiativeRuleRead = {
  initiativeId: string;
  status: "ok" | "unavailable";
  rules: InitiativeRulePreview[] | null;
};

/**
 * 规则读面取数（#596）：仅 Owner/Admin（manage_events）且 event 场景发查询；
 * 无权/失败一律降级为 unavailable（不阻塞编辑与保存，不展示错误块）。
 */
function useInitiativeMountPreview(
  workspaceId: string | undefined,
  initiativeId: string | null,
  enabled: boolean,
): InitiativeRuleRead | null {
  const [state, setState] = useState<InitiativeRuleRead | null>(null);

  useEffect(() => {
    if (!enabled || !workspaceId || !initiativeId) return;
    let cancelled = false;

    fetchInitiativeMountPreview(workspaceId, initiativeId)
      .then((preview) => {
        if (cancelled) return;
        setState({
          initiativeId,
          status: preview ? "ok" : "unavailable",
          rules: preview?.rules ?? null,
        });
      })
      .catch(() => {
        // 失败 ≠ 无规则：只降级，不误报「无规则」
        if (!cancelled) setState({ initiativeId, status: "unavailable", rules: null });
      });

    return () => {
      cancelled = true;
    };
  }, [workspaceId, initiativeId, enabled]);

  return state && state.initiativeId === initiativeId ? state : null;
}

/** valueJson 解析（与 AdminInitiativeRule 同口径）；坏 JSON/缺规则 → null（降级，不抛） */
function ruleOf<T>(
  rules: InitiativeRulePreview[] | null,
  key: string,
): { value: T | null; locked: boolean } | null {
  const rule = rules?.find((row) => row.key === key);
  if (!rule) return null;
  try {
    return { value: JSON.parse(rule.valueJson) as T, locked: rule.locked };
  } catch {
    return { value: null, locked: rule.locked };
  }
}

/** 规则来源标签：locked = 平台锁死；default = 默认规则（挂载时快照） */
function RuleSourceTag({ ruleKey, locked }: { ruleKey: string; locked: boolean | null }) {
  const t = useTranslations("offerings");
  if (locked === null) return null;
  return (
    <span
      className="ml-1 rounded border border-line px-1 text-xs text-ink-3"
      data-testid={`initiative-rule-source-${ruleKey}`}
    >
      {locked ? t("initiativeRuleSourceLocked") : t("initiativeRuleSourceDefault")}
    </span>
  );
}

/**
 * 倡导活动规则面板（#596）：两种模式共用一块
 *
 * - preview：挂载前预览——值取规则原始值（含 `deadline_rule` 按草稿 startsAt 推算
 *   的截止时刻）；挂载尚未发生，只答「挂上去会怎样」；
 * - applied：已挂载摘要——四项都取 Event 生效值（押金与缴费槽同源），来源标签由
 *   规则锁态标注（locked=平台锁死不可改 / default=挂载时快照）。
 *
 * 规则读面不可读/失败时（rules === null）只显示现值 + 既有通用提示，不显示来源标签。
 * 施加态如此降级；预览态（尚无现值可显示）由调用方整块不渲染：**有意的静默降级**
 * ——fail-closed，不把「读不到规则」当「没有规则」上报（#596 裁决）。
 */
function InitiativeRulesPanel({
  mode,
  rules,
  applied,
  startsAt,
  locale,
}: {
  mode: "preview" | "applied";
  rules: InitiativeRulePreview[] | null;
  applied: {
    depositEnabled: boolean;
    depositAmountCents: number | null;
    minAge: number | null;
    minParticipants: number | null;
    registrationDeadline: string | null;
  } | null;
  startsAt: string | null;
  locale: string;
}) {
  const t = useTranslations("offerings");
  const tCommon = useTranslations("common");

  const deposit = ruleOf<{ enabled?: boolean; amount_cents?: number | null }>(rules, "deposit");
  const ageGate = ruleOf<{ min_age?: number }>(rules, "age_gate");
  const minParticipants = ruleOf<{ count?: number }>(rules, "min_participants");
  const deadlineRule = ruleOf<{ hours_before_start?: number }>(rules, "deadline_rule");

  const depositAmountCents =
    mode === "preview"
      ? deposit?.value?.enabled
        ? (deposit.value.amount_cents ?? 0)
        : null
      : applied?.depositEnabled
        ? (applied.depositAmountCents ?? 0)
        : null;

  const minAge = mode === "preview" ? (ageGate?.value?.min_age ?? null) : (applied?.minAge ?? null);

  const minCount =
    mode === "preview"
      ? (minParticipants?.value?.count ?? null)
      : (applied?.minParticipants ?? null);

  // 预览态的截止只能是规则形态：有 startsAt 才算得出具体时刻（否则提示需先定开始时间）
  const hoursBeforeStart = deadlineRule?.value?.hours_before_start ?? null;
  const startMs = startsAt ? new Date(startsAt).getTime() : Number.NaN;
  const previewDeadlineIso =
    hoursBeforeStart !== null && !Number.isNaN(startMs)
      ? new Date(startMs - hoursBeforeStart * 3600_000).toISOString()
      : null;

  const deadline =
    mode === "preview" ? previewDeadlineIso : (applied?.registrationDeadline ?? null);

  const deadlineText =
    deadline !== null
      ? t("initiativeRuleDeadline", {
          deadline: formatDeadline(deadline, tCommon("noDeadline"), locale),
        })
      : mode === "preview" && hoursBeforeStart !== null
        ? t("initiativeRuleDeadlinePending", { hours: hoursBeforeStart })
        : t("initiativeRuleDeadlineOff");

  return (
    <div
      className="block rounded-large border border-line bg-soft-2 px-3 py-2"
      data-testid="initiative-rules-summary"
      data-state={mode}
    >
      <span className="block text-[13px] text-ink-3">
        {mode === "preview" ? t("initiativeRulePreviewTitle") : t("initiativeRulesTitle")}
      </span>
      <ul className="mt-1 space-y-0.5 text-sm text-ink">
        <li data-testid="initiative-rule-deposit">
          {depositAmountCents !== null
            ? t("initiativeRuleDeposit", { amount: formatAmountShort(depositAmountCents) })
            : t("initiativeRuleDepositOff")}
          <RuleSourceTag ruleKey="deposit" locked={deposit?.locked ?? null} />
        </li>
        <li data-testid="initiative-rule-age">
          {minAge !== null ? t("initiativeRuleAge", { age: minAge }) : t("initiativeRuleAgeOff")}
          <RuleSourceTag ruleKey="age_gate" locked={ageGate?.locked ?? null} />
        </li>
        <li data-testid="initiative-rule-min">
          {minCount !== null ? t("initiativeRuleMin", { count: minCount }) : t("initiativeRuleMinOff")}
          <RuleSourceTag ruleKey="min_participants" locked={minParticipants?.locked ?? null} />
        </li>
        <li data-testid="initiative-rule-deadline">
          {deadlineText}
          <RuleSourceTag ruleKey="deadline_rule" locked={deadlineRule?.locked ?? null} />
        </li>
      </ul>
      <span className="mt-1 block text-xs text-ink-3">
        {mode === "preview" ? t("initiativeRulePreviewHint") : t("initiativeRulesHint")}
      </span>
    </div>
  );
}

/**
 * #624 解除挂载来源标记（后端 `detached_rule_provenance`，JsonString）。
 * 形状与 #596 写响应 applied 同源：initiative 身份 + 逐字段 value/source。
 */
type DetachedRuleField = { value: unknown; source: string };
type DetachedRuleProvenance = {
  initiative: { id: string; name: string; slug: string };
  fields: Record<string, DetachedRuleField>;
};

/** JsonString 解析（与 venue/priceTiers 同纪律）；坏 JSON/缺身份 → null（降级不抛） */
function parseDetachedRuleProvenance(
  raw: string | null | undefined,
): DetachedRuleProvenance | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as DetachedRuleProvenance;
    if (
      !parsed ||
      typeof parsed !== "object" ||
      typeof parsed.initiative?.name !== "string" ||
      !parsed.fields ||
      typeof parsed.fields !== "object"
    ) {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

function numberOf(field: DetachedRuleField | undefined): number | null {
  return typeof field?.value === "number" ? field.value : null;
}

function textOf(field: DetachedRuleField | undefined): string | null {
  return typeof field?.value === "string" ? field.value : null;
}

/**
 * 「来自已解除的倡导活动《name》」面板（#624 方案 C）：detach 后强制值留在场上，
 * 这里逐字段展示它们的来源；场主改写某字段并保存成功后，该行随标记一起消失。
 *
 * 只在 detachedRuleProvenance 非空时渲染（重挂载/全部字段已改写 → 整块不渲染）。
 * course 无此治理面（Event 独有），调用方按 kind 门控。
 */
function DetachedRuleProvenancePanel({
  provenance,
}: {
  provenance: DetachedRuleProvenance;
}) {
  const t = useTranslations("offerings");
  const tCommon = useTranslations("common");
  const locale = useLocale();
  const f = provenance.fields;

  // 押金规则写两个 event 字段（开关 + 金额），清除是逐字段的：只改了金额时
  // `deposit_amount_cents` 键消失、`deposit_enabled` 仍留——此时不得编造 ¥0，
  // 只陈述仍被标记的开关本身（值以标记为准，不读 Event 现值，以免把场主已改的
  // 金额算回平台来源）。
  const depositEnabledMarked = "deposit_enabled" in f;
  const depositCents = numberOf(f.deposit_amount_cents);
  const minAge = numberOf(f.min_age);
  const minCount = numberOf(f.min_participants);
  const deadline = textOf(f.registration_deadline);

  // 渲染顺序与既有规则摘要一致（押金 → 年龄 → 人数 → 截止）；未标记字段不渲染行
  const rows: Array<{ key: string; text: string }> = [];
  if (depositEnabledMarked && f.deposit_enabled?.value === true) {
    rows.push({
      key: "deposit",
      text:
        depositCents !== null
          ? t("initiativeRuleDeposit", {
              amount: formatAmountShort(depositCents),
            })
          : t("initiativeRuleDepositOn"),
    });
  } else if (depositEnabledMarked) {
    rows.push({ key: "deposit", text: t("initiativeRuleDepositOff") });
  } else if (depositCents !== null) {
    // 防御（后端不会产生只有金额键的标记）：只陈述金额，不推断开关
    rows.push({
      key: "deposit",
      text: t("initiativeRuleDeposit", {
        amount: formatAmountShort(depositCents),
      }),
    });
  }
  if (minAge !== null) {
    rows.push({ key: "age_gate", text: t("initiativeRuleAge", { age: minAge }) });
  }
  if (minCount !== null) {
    rows.push({
      key: "min_participants",
      text: t("initiativeRuleMin", { count: minCount }),
    });
  }
  if (deadline !== null) {
    rows.push({
      key: "deadline_rule",
      text: t("initiativeRuleDeadline", {
        deadline: formatDeadline(deadline, tCommon("noDeadline"), locale),
      }),
    });
  }

  return (
    <div
      className="block rounded-large border border-line bg-soft-2 px-3 py-2"
      data-testid="initiative-detached-provenance"
      data-state="detached"
    >
      <span className="block text-[13px] text-ink-3">
        {t("initiativeDetachedRuleTitle", { name: provenance.initiative.name })}
      </span>
      <ul className="mt-1 space-y-0.5 text-sm text-ink">
        {rows.map((row) => (
          <li
            key={row.key}
            data-testid={`initiative-detached-rule-${row.key}`}
            data-state="detached"
          >
            {row.text}
          </li>
        ))}
      </ul>
      <span className="mt-1 block text-xs text-ink-3">
        {t("initiativeDetachedRuleHint")}
      </span>
    </div>
  );
}

/**
 * 缴费槽三态录入（event-deposit U9/KTD10/R1/R10）：免费 / 定价档位 / 押金单选，
 * 三态互斥由构造保证（切换即清空另一侧草稿）。course 无押金槽（两态）。
 *
 * 只读门（R3）：挂载 Initiative 的场，押金由 Initiative 规则提供——押金选项与
 * 金额禁用并展示来源；押金已开启时整槽只读（关闭押金同样是押金字段写入，锁死
 * 态后端会拒绝，前端不制造必然失败的提交）。
 */
function PaymentSlotFields({
  kind,
  mode,
  onModeChange,
  tierDrafts,
  onTierDraftsChange,
  depositAmount,
  onDepositAmountChange,
  depositDisabled = false,
  modeDisabled = false,
  sourceNote = null,
}: {
  kind: OfferingKind;
  mode: PaymentMode;
  onModeChange: (mode: PaymentMode) => void;
  tierDrafts: TierDraft[];
  onTierDraftsChange: (drafts: TierDraft[]) => void;
  /** 押金金额元草稿（分转换在保存/提交时做） */
  depositAmount: string;
  onDepositAmountChange: (value: string) => void;
  /** 押金选项与金额只读（Initiative 挂载场；默认 false） */
  depositDisabled?: boolean;
  /** 整槽只读（Initiative 挂载且押金已开启；默认 false） */
  modeDisabled?: boolean;
  /** 押金来源提示（挂载场；默认无） */
  sourceNote?: string | null;
}) {
  const t = useTranslations("offerings");
  const modes = kind === "event" ? PAYMENT_MODES : COURSE_PAYMENT_MODES;

  return (
    <div className="grid gap-2" data-testid="payment-slot" data-mode={mode}>
      <fieldset className="grid gap-2">
        <legend className="text-[13px] text-ink-3">{t("fieldPaymentMode")}</legend>
        {modes.map((option) => (
          <label key={option} className="flex items-center gap-2 text-sm text-ink-2">
            <input
              type="radio"
              name="payment-mode"
              value={option}
              checked={mode === option}
              disabled={modeDisabled || (option === "deposit" && depositDisabled)}
              onChange={() => onModeChange(option)}
              data-testid={`payment-mode-${option}`}
            />
            {t(PAYMENT_MODE_LABEL[option])}
          </label>
        ))}
      </fieldset>

      {mode === "pricing" ? (
        <TierEditor drafts={tierDrafts} onChange={onTierDraftsChange} manage />
      ) : null}

      {mode === "deposit" ? (
        <label className="block">
          <span className="block text-[13px] text-ink-3">
            {t("depositAmountLabel")}
          </span>
          <input
            type="number"
            min={0.01}
            step="0.01"
            inputMode="decimal"
            value={depositAmount}
            disabled={depositDisabled || modeDisabled}
            onChange={(e) => onDepositAmountChange(e.target.value)}
            data-testid="deposit-amount-input"
            className="ui-input mt-1 w-full"
          />
          <span className="mt-1 block text-xs text-ink-3">
            {t("depositRefundHint")}
          </span>
        </label>
      ) : null}

      {sourceNote ? (
        <p className="text-xs text-ink-3" data-testid="payment-slot-source">
          {sourceNote}
        </p>
      ) : null}
    </div>
  );
}

/* ---------------- 列表页 ---------------- */

interface OfferingsState {
  wsId: string;
  rows: OfferingItem[] | null;
  /** 本人活跃报名（行内状态徽标）；未登录 / 未就绪 = 空数组 */
  myEnrollments: ActiveEnrollmentRow[];
  error: string | null;
}

function OfferingRow({
  offering,
  slug,
  kind,
  myStatus,
}: {
  offering: OfferingItem;
  slug: string;
  kind: OfferingKind;
  /** 本人对该行的活跃报名状态（无 → 不渲染徽标） */
  myStatus?: MyEnrollmentStatus;
}) {
  const t = useTranslations("offerings");
  const tCommon = useTranslations("common");
  const labelsT = useTranslations();
  const locale = useLocale();
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
          {myStatus ? (
            <span
              className="inline-flex flex-none items-center rounded-full border border-accent bg-accent-mentionbg px-2 py-0.5 text-[12px] leading-4 text-[var(--accent-strong)]"
              data-testid={`my-enrollment-${myStatus}`}
            >
              {t(MY_ENROLLMENT_STATUS_LABEL[myStatus])}
            </span>
          ) : null}
          <span>{labelsT(ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy])}</span>
          <span>·</span>
          <span>{labelsT(VISIBILITY_LABEL[offering.visibility])}</span>
          <span>·</span>
          <span>
            {t("deadlineLabel", {
              deadline: formatDeadline(
                offering.registrationDeadline,
                tCommon("noDeadline"),
                locale,
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
  const { userId } = useAuthed();
  const [state, setState] = useState<OfferingsState>({
    wsId: "",
    rows: null,
    myEnrollments: [],
    error: null,
  });

  useEffect(() => {
    if (!ws) return;

    let cancelled = false;

    // 个人报名状态与列表并发取数（未登录跳过第二条；失败整块走错误态）
    Promise.all([
      fetchWorkspaceOfferings(ws.id, kind),
      userId ? fetchMyActiveEnrollments() : Promise.resolve([]),
    ])
      .then(([rows, myEnrollments]) => {
        if (!cancelled)
          setState({ wsId: ws.id, rows, myEnrollments, error: null });
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setState({
            wsId: ws.id,
            rows: null,
            myEnrollments: [],
            error: e instanceof Error ? e.message : t("loadFailed"),
          });
        }
      });

    return () => {
      cancelled = true;
    };
  }, [ws, kind, t, userId]);

  const stale = ws ? state.wsId !== ws.id : false;
  const rows = stale ? null : state.rows;
  const loadError = stale ? null : state.error;
  const myEnrollments = stale ? [] : state.myEnrollments;
  // 行内状态索引：课程按 courseId、活动按 eventId 对齐；只收活跃态
  const myStatusById = new Map<string, MyEnrollmentStatus>();
  for (const enrollment of myEnrollments) {
    const key = kind === "course" ? enrollment.courseId : enrollment.eventId;
    if (key && enrollment.status in MY_ENROLLMENT_STATUS_LABEL) {
      myStatusById.set(key, enrollment.status as MyEnrollmentStatus);
    }
  }
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
          <div className="mt-8 rounded-large border border-line bg-card p-6 text-sm text-ink-3">
            {t("loadFailed")}
          </div>
        ) : wsLoading || rows === null ? (
          <div className="mt-8 h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
        ) : rows.length === 0 ? (
          <div className="mt-8 rounded-large border border-dashed border-line bg-card p-10 text-center text-sm text-ink-3">
            {t("empty", { label: labelsT(label) })}
            {manage ? t("emptyCreateHint", { label: labelsT(label) }) : t("emptyWaitHint")}
          </div>
        ) : (
          <div className="mt-8 grid gap-3">
            {rows.map((offering) => (
              <OfferingRow
                key={offering.id}
                offering={offering}
                slug={slug}
                kind={kind}
                myStatus={myStatusById.get(offering.id)}
              />
            ))}
          </div>
        )}
      </div>
    </WorkspaceShell>
  );
}

/* ---------------- 详情/管理页 ---------------- */

/** curriculum_requirements(JsonString)与自由文本互转(U8/R12:Q10 自由文本语义) */
function parseCurriculumText(json: string | null | undefined): string {
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

function buildCurriculumJson(text: string): string {
  return JSON.stringify({ note: text });
}

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
  /** 缴费槽（U9/KTD10/R1）：三态单选（免费 / 定价档位 / 押金）+ 档位草稿 */
  mode: PaymentMode;
  /** 押金金额元草稿（分转换在保存时做；定价/免费态不下发） */
  depositAmount: string;
  tierDrafts: TierDraft[];
  initiativeId: string | null;
  /** #624 报名门槛（仅 event）：数字草稿（"" = 清除/null）；locked 规则下禁用 */
  minAge: string;
  minParticipants: string;
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
  const locale = useLocale();
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
  const [initiatives, setInitiatives] = useState<PublicInitiativeCard[]>([]);
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
    enrollment: {
      id: string;
      status: string;
      approvalDeadline?: string | null;
    } | null;
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
  // 渲染期时间快照（react-hooks/purity：渲染体不得直接调 Date.now；仓内
  // payment-checkout-dialog/approval-chip 同款惰性初始化）
  const [nowMs] = useState(() => Date.now());

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

  const loadInitiatives = () => {
    if (initiatives.length > 0 || kind !== "event") return;
    void fetchPublicInitiatives()
      .then((rows) =>
        setInitiatives(
          rows.filter(
            (row) => row.status === "open" || row.id === offering?.initiativeId,
          ),
        ),
      )
      .catch(() => setInitiatives([]));
  };

  // 已挂载 Event 需要当前 Initiative 名称回显（含 closed Initiative 留档场）；
  // 草稿期下拉本就在聚焦时加载，此处只对已挂载场景提前拉取。
  useEffect(() => {
    if (offering?.initiativeId) loadInitiatives();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [offering?.initiativeId]);

  // 收费目标：可售档位（R2 后端已过滤过期档）与所选档（R5 报名须选档）
  const priceTiers = parsePriceTiers(offering?.availablePriceTiers);
  const [tierId, setTierId] = useState<string | null>(null);
  // 默认选中第一档（产品拍板:有可售档不该强制手点;可再点换档）——派生值
  // 而非 effect 补 setState（react-hooks/set-state-in-effect）;?? 保留用户已选。
  const effectiveTierId = tierId ?? priceTiers[0]?.id ?? null;
  const paidTier = priceTiers.find((t) => t.id === effectiveTierId) ?? null;
  // 开收银模态框：收费目标带所选档上下文（金额/档名/标题），复访承接可不带
  function openCheckoutFor(enrollmentId: string) {
    const tier = priceTiers.find((t) => t.id === effectiveTierId) ?? null;
    setCheckout({
      enrollmentId,
      amountCents: tier?.amountCents ?? null,
      tierName: tier?.name ?? null,
      title: offering?.title ?? "",
    });
  }

  const loadError = stale ? null : state.error;
  const manage = ws ? canManageEvents(ws.myAbilities) : false;
  // 缴费槽单一口径（U9/KTD10/R10/AE8）：三态互斥显示，押金场只出现
  // 「押金 ¥xx（到场退）」，不再与「免费」并列。来源提示（R3）：挂载 Initiative
  // 的场押金由规则提供；Web 侧读不到 per-rule 锁态（AdminInitiativeRule 仅平台
  // 管理员可读），故按「挂载 + 押金已开启」呈现为只读来源。
  const paymentMode = offering ? paymentModeOf(offering) : "free";
  const initiativeGovernsDeposit =
    kind === "event" && offering?.initiativeId != null;
  const initiativeName = offering?.initiativeId
    ? (initiatives.find((row) => row.id === offering.initiativeId)?.name ?? null)
    : null;
  const paymentSlotSource = initiativeGovernsDeposit
    ? initiativeName
      ? t("paymentSlotSourceNamed", { name: initiativeName })
      : t("paymentSlotSourceGeneric")
    : null;
  // 押金已开启的挂载场：整槽只读（关闭押金同样是押金字段写入，锁死态后端拒绝）
  const paymentSlotLocked = initiativeGovernsDeposit && paymentMode === "deposit";
  // 教研角色（tutor/owner/admin）可见课程内容治理入口；能力面无法区分 tutor 与普通成员，须看角色标签
  const teachingStaff = (ws?.myRoleNames ?? []).some((role) =>
    TEACHING_ROLE_NAMES.includes(role),
  );

  // issue #505 D1：配套课程卡（仅 event；成员视角链工作台课程详情）
  const companionCourse =
    kind === "event" && offering
      ? parseCompanionCourse(offering.companionCourse)
      : null;

  // 现场核销入口（#558/#559 后续）：门 = eventModerators 查询自门——主理人或
  // Owner/Admin 可读（后端 Moderators.list 走 can_moderate?），普通成员查询
  // forbidden → 隐藏（与小程序/外部端同口径：没这个角色就看不到）。查询成功
  // 时按「我在列表 ∨ manage_events」判定。
  const [canCheckIn, setCanCheckIn] = useState(false);
  useEffect(() => {
    if (kind !== "event" || !ws || !userId || !id) return;
    let cancelled = false;
    fetchEventModerators(ws.id, id)
      .then((mods) => {
        if (cancelled) return;
        setCanCheckIn(manage || mods.some((row) => row.userId === userId));
      })
      .catch(() => {
        if (!cancelled) setCanCheckIn(false);
      });
    return () => {
      cancelled = true;
    };
  }, [ws, id, kind, userId, manage]);

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

  // useMemo 稳定引用：字面量分支每渲染新建对象，会令 soldTierTouched 的
  // useMemo 依赖（activeDraft）每渲染变化而失效（react-hooks lint 强制）
  const activeDraft: MetaDraft | null = useMemo(
    () =>
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
              curriculumRequirements: parseCurriculumText(
                offering.curriculumRequirements,
              ),
              // KTD9：读全量 priceTiers（含过期档），防止保存静默丢弃过期档
              mode: paymentModeOf(offering),
              depositAmount: depositAmountDraft(offering.depositAmountCents ?? null),
              tierDrafts: toDraft(offering.priceTiers),
              initiativeId: offering.initiativeId ?? null,
              minAge: offering.minAge == null ? "" : String(offering.minAge),
              minParticipants:
                offering.minParticipants == null
                  ? ""
                  : String(offering.minParticipants),
            }
          : null,
    [metaDraft, offering],
  );

  // #596 规则面板：草稿选中的 Initiative 与已挂载的一致 → applied（Event 生效值 +
  // 规则锁态）；选了尚未保存的新 Initiative → preview（只看规则，不动 Event 值）。
  const draftInitiativeId = activeDraft?.initiativeId ?? null;
  const mountedInitiativeId = offering?.initiativeId ?? null;
  const ruleRead = useInitiativeMountPreview(
    ws?.id,
    draftInitiativeId,
    manage && kind === "event",
  );
  const ruleMode: "preview" | "applied" | null =
    kind !== "event" || !draftInitiativeId
      ? null
      : draftInitiativeId === mountedInitiativeId
        ? "applied"
        : "preview";

  // #624 解除挂载来源标记：随 Event 一起读（页面重载后仍在）；全部字段被改写或
  // 重挂载后后端置 nil → 整块不渲染。
  const detachedProvenance =
    kind === "event" ? parseDetachedRuleProvenance(offering?.detachedRuleProvenance) : null;

  // 挂载中且规则锁死 → 门槛输入禁用（不制造必然失败的提交，PaymentSlotFields 同款）；
  // 规则读面不可读（降级）时不锁，交给后端拒绝。
  const ruleLocked = (key: string): boolean =>
    ruleMode === "applied" && ruleOf(ruleRead?.rules ?? null, key)?.locked === true;
  const minAgeLocked = ruleLocked("age_gate");
  const minParticipantsLocked = ruleLocked("min_participants");
  // 挂载预览（草稿选了另一个 Initiative）：保存时新规则会强制覆盖这两项，就地录入
  // 无意义且会留下「先编辑、再切回被锁状态」的非法草稿值 → 预览态一并禁用。
  const thresholdsLocked = (locked: boolean): "locked" | "preview" | "editable" =>
    locked ? "locked" : ruleMode === "preview" ? "preview" : "editable";

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
          offeringErrorText(
            res.errors[0],
            "saveFailedRetry",
            t,
            translatePaymentError,
          ),
        );
      }
    } catch (e: unknown) {
      setSaveMessage(
        offeringErrorText(
          e instanceof Error ? { message: e.message } : null,
          "saveFailedRetry",
          t,
          translatePaymentError,
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
    // U9 三态：服务端定价开、草稿切到免费或押金都算「关收费」。
    const draftPricing = activeDraft.mode === "pricing";
    const disabling = offering.pricingEnabled === true && !draftPricing;
    const enabling = offering.pricingEnabled !== true && draftPricing;
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
    const draftPricing = activeDraft.mode === "pricing";
    // review F11：校验前置（setSaveBusy 之前）——无效档位不再把保存按钮
    // 永久卡死；混合有效/无效行拒绝整次提交（不静默丢弃无效行）。
    // 档位草稿仅在定价态参与校验：切到押金/免费时档位随 payload 清空，
    // 遗留的编辑中行不该拦住与档位无关的保存。
    const validTiers =
      activeDraft.tierDrafts.map(fromDraft).filter((x) => x !== null);
    if (draftPricing) {
      if (
        activeDraft.tierDrafts.length > 0 &&
        validTiers.length !== activeDraft.tierDrafts.length
      ) {
        setSaveMessage(t("pricingTierInvalid"));
        return;
      }
      if (validTiers.length === 0) {
        setSaveMessage(t("pricingTierRequired"));
        return;
      }
    }
    // 押金态前置校验（U3 后端同款判据：正金额 + ends_at 结算锚点 +
    // 报名截止自助取消锚点，B②）
    const depositCents = depositAmountToCents(activeDraft.depositAmount);
    // #624 报名门槛（仅 event）："" = 清除（null）；非法值就地拦截，不提交
    const minAge = positiveIntOrNull(activeDraft.minAge);
    const minParticipants = positiveIntOrNull(activeDraft.minParticipants);
    if (kind === "event" && (minAge === undefined || minParticipants === undefined)) {
      setSaveMessage(t("thresholdPositiveIntRequired"));
      return;
    }
    // review F7：缴费槽脏检查——仅当三态或档位相对服务端快照变化时下发缴费键，
    // 普通 metadata 保存不再整段重发缴费快照（消除陈旧管理员把已关闭的收费
    // 连旧档位一起恢复的除改窗口；服务端值仍是唯一真源）
    const paymentDirty = paymentSlotChanged({
      kind,
      server: offering,
      mode: activeDraft.mode,
      depositAmountCents: depositCents,
      pricingDirty:
        offering.pricingEnabled !== draftPricing ||
        JSON.stringify(toDraft(offering.priceTiers)) !==
          JSON.stringify(activeDraft.tierDrafts),
    });

    // #624 门槛字段同款脏检查（F7 纪律）：未改不下发——陈旧页面不得用旧值覆盖
    // 挂载中由规则强制/传播写入的新值；且后端「同值不算场主的决定」语义因此
    // 只需兜底强制路径（#624 逐字段清标记的前提就是「值确有变化」）
    const minAgeDirty =
      activeDraft.minAge !== (offering.minAge == null ? "" : String(offering.minAge));
    const minParticipantsDirty =
      activeDraft.minParticipants !==
      (offering.minParticipants == null ? "" : String(offering.minParticipants));
    // 截止时间同款脏检查：datetime-local 只到分钟，未改动时重发会把库里的秒截断
    // ——既误清 #624 标记键（「首改即清」被破坏），又让挂载中锁死 deadline_rule 的
    // 普通元数据保存撞上 "initiative rule deadline_rule is locked"（既有缺陷）。
    const registrationDeadlineDirty =
      activeDraft.deadline !== toLocalInput(offering.registrationDeadline ?? null);

    if (activeDraft.mode === "deposit") {
      if (depositCents === null) {
        setSaveMessage(t("depositAmountRequired"));
        return;
      }
      if (activeDraft.endsAt.trim() === "") {
        setSaveMessage(t("depositEndsAtRequired"));
        return;
      }
      // 截止必填与后端 PaymentModeValidation 同口径：只在缴费槽本次被写入
      // （paymentDirty）时要求——挂载锁死槽/未动缴费槽的普通元数据保存不受限
      if (paymentDirty && activeDraft.deadline.trim() === "") {
        setSaveMessage(t("depositDeadlineRequired"));
        return;
      }
    }

    setSaveBusy(true);
    setSaveMessage(null);
    try {
      const res = await updateOffering(offering.id, kind, {
        title: activeDraft.title,
        enrollmentPolicy: activeDraft.enrollmentPolicy,
        capacity:
          activeDraft.capacity === "" ? null : Number(activeDraft.capacity),
        // 未改动不下发（见 registrationDeadlineDirty）：避免分钟级重序列化截断秒
        ...(registrationDeadlineDirty
          ? { registrationDeadline: fromLocalInput(activeDraft.deadline) }
          : {}),
        startsAt: fromLocalInput(activeDraft.startsAt),
        endsAt: fromLocalInput(activeDraft.endsAt),
        ...(kind === "event" && (offering.initiativeId || activeDraft.initiativeId)
          ? { initiativeId: activeDraft.initiativeId }
          : {}),
        // #624：门槛字段仅 event 有（course 无此两列，误传会被 GraphQL 拒绝）；
        // 未改动不下发（见 minAgeDirty / minParticipantsDirty）
        ...(kind === "event"
          ? {
              ...(minAgeDirty ? { minAge } : {}),
              ...(minParticipantsDirty ? { minParticipants } : {}),
            }
          : {}),
        ...(kind === "course"
          ? {
              curriculumRequirements: buildCurriculumJson(
                activeDraft.curriculumRequirements,
              ),
            }
          : { venue: activeDraft.venue }),
        ...(paymentDirty
          ? paymentSlotPayload({
              kind,
              mode: activeDraft.mode,
              tiers: validTiers.map((tier) => JSON.stringify(tier)),
              depositAmountCents: depositCents,
            })
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
            initiativeId: res.result.initiativeId ?? null,
            ...(kind === "event" ? { venue: res.result.venue ?? null } : {}),
            ...(res.result.pricingEnabled !== undefined
              ? { pricingEnabled: res.result.pricingEnabled }
              : {}),
            ...(res.result.priceTiers !== undefined
              ? { priceTiers: res.result.priceTiers }
              : {}),
            ...(res.result.depositEnabled !== undefined
              ? { depositEnabled: res.result.depositEnabled }
              : {}),
            ...(res.result.depositAmountCents !== undefined
              ? { depositAmountCents: res.result.depositAmountCents }
              : {}),
            // #596：挂载/换挂载会强制写入年龄与成班人数，保存后必须就地更新，
            // 否则规则摘要会出现「年龄门槛：无 + 平台锁死」的自相矛盾
            ...(res.result.minAge !== undefined ? { minAge: res.result.minAge } : {}),
            ...(res.result.minParticipants !== undefined
              ? { minParticipants: res.result.minParticipants }
              : {}),
            // #624：改写标记内字段后后端逐字段清除来源标记，保存响应即新标记
            // （全部改写/重挂载 → null，面板随之消失），无需整页重载
            ...(kind === "event"
              ? {
                  detachedRuleProvenance:
                    res.result.detachedRuleProvenance ?? null,
                }
              : {}),
          },
          error: null,
        });
        setMetaDraft(null);
        setSaveMessage(t("saved"));
      } else {
        setSaveMessage(
          offeringErrorText(
            res.errors[0],
            "saveFailedRetry",
            t,
            translatePaymentError,
          ),
        );
      }
    } catch (e: unknown) {
      setSaveMessage(
        offeringErrorText(
          e instanceof Error ? { message: e.message } : null,
          "saveFailedRetry",
          t,
          translatePaymentError,
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
          offeringErrorText(
            res.errors[0],
            "actionFailedRetry",
            t,
            translatePaymentError,
          ),
        );
      }
    } catch (e: unknown) {
      setSaveMessage(
        offeringErrorText(
          e instanceof Error ? { message: e.message } : null,
          "actionFailedRetry",
          t,
          translatePaymentError,
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
    if (offering.pricingEnabled && !effectiveTierId) {
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
        tierId: effectiveTierId,
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

  // 报名成功/已报名后的后续出口（P0-1）：课程给「进入课程」主 CTA——未开课
  // 按 startsAt 分叉文案（课程内容未就绪时不把用户送进空阅读页）；活动给
  // 「我的报名」（/participations?tab=enrollments）出口 + 「添加日历」（P1a，
  // 有 startsAt 才渲染）。课程次级出口落在 /learning（P2b 后 /participations
  // 不再有学习 tab）。submitState 成功态与回访态共用。
  function enrollmentFollowUp() {
    if (!offering) return null;
    const startsAtMs = offering.startsAt
      ? new Date(offering.startsAt).getTime()
      : null;
    const notStarted = startsAtMs !== null && startsAtMs > nowMs;
    return (
      <div className="mt-2 grid gap-2 justify-self-start">
        {kind === "course" ? (
          <Link
            href={`/learning/courses/${offering.id}`}
            data-testid="enrollment-enter-course"
            className="justify-self-start rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line"
          >
            {notStarted
              ? t("enterCourseAfterStart", {
                  time: formatDeadline(
                    offering.startsAt ?? null,
                    tCommon("timeTbd"),
                    locale,
                  ),
                })
              : t("enterCourse")}
          </Link>
        ) : null}
        {kind === "event" ? (
          <AddToCalendar
            eventId={offering.id}
            title={offering.title}
            startsAt={offering.startsAt ?? null}
            endsAt={offering.endsAt ?? null}
            venue={formatVenue(parseVenue(offering.venue))}
          />
        ) : null}
        <Link
          href={kind === "event" ? "/participations?tab=enrollments" : "/learning"}
          className="text-[13px] text-accent hover:underline"
        >
          {kind === "event" ? t("viewInParticipations") : t("viewInLearning")}
        </Link>
      </div>
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

            <div className="mt-8 grid gap-4 sm:grid-cols-2">
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
                      locale,
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
                  {/* R10/AE8：单一缴费槽（免费 / 收费 ¥xx / 押金 ¥xx（到场退）），
                      不再出现「收费：免费」与「押金：¥69」并列 */}
                  <Field label={t("fieldPaymentMode")}>
                    {paymentMode === "deposit"
                      ? t("paymentSlotDeposit", {
                          amount: formatAmountShort(
                            offering.depositAmountCents ?? 0,
                          ),
                        })
                      : paymentMode === "pricing"
                        ? t("paymentSlotPricing", {
                            overview:
                              parsePriceTiers(offering.availablePriceTiers)
                                .map(
                                  (tier) =>
                                    `${tier.name} ¥${formatAmountShort(tier.amountCents)}`,
                                )
                                .join(" / ") || t("noTier"),
                          })
                        : t("paymentSlotFree")}
                  </Field>
                </div>
              </div>

              {teachingStaff && kind === "course" ? (
                <div
                  className="rounded-large border border-line bg-card p-6"
                  data-testid="course-governance-card"
                >
                  <h2 className="text-sm font-medium text-ink">
                    {t("researchTitle")}
                  </h2>
                  <Link
                    href={`/w/${slug}/courses/${offering.id}/curriculum`}
                    className="mt-4 inline-flex text-sm text-accent hover:underline"
                    data-testid="course-governance-link"
                  >
                    {t("openCurriculum")} ↗
                  </Link>
                </div>
              ) : null}

              {canCheckIn && kind === "event" ? (
                <div
                  className="rounded-large border border-line bg-card p-6"
                  data-testid="check-in-entry-card"
                >
                  <h2 className="text-sm font-medium text-ink">
                    {t("checkInEntryTitle")}
                  </h2>
                  <Link
                    href={`/w/${slug}/events/${offering.id}/check-in`}
                    className="mt-4 inline-flex text-sm text-accent hover:underline"
                    data-testid="check-in-entry-link"
                  >
                    {t("checkInEntryLink")} ↗
                  </Link>
                </div>
              ) : null}

              {companionCourse ? (
                <div
                  className="rounded-large border border-line bg-card p-6"
                  data-testid="companion-course-card"
                >
                  <h2 className="text-sm font-medium text-ink">
                    {t("companionCourseTitle")}
                  </h2>
                  <Link
                    href={`/w/${slug}/courses/${companionCourse.id}`}
                    className="mt-4 inline-flex text-sm text-accent hover:underline"
                  >
                    {companionCourse.title} ↗
                  </Link>
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
                        className="ui-input mt-1 w-full"
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
                        className="ui-select mt-1 w-full"
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
                        className="ui-input mt-1 w-full"
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
                        className="ui-input mt-1 w-full"
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
                      <label className="block">
                        <span className="block text-[13px] text-ink-3">{t("initiativeLabel")}</span>
                        <select
                          value={activeDraft.initiativeId ?? ""}
                          onFocus={loadInitiatives}
                          onChange={(e) => setMetaDraft({ ...activeDraft, initiativeId: e.target.value || null })}
                          disabled={offering.status !== "draft"}
                          className="ui-select mt-1 w-full"
                        >
                          <option value="">{t("initiativeNone")}</option>
                          {initiatives.map((initiative) => (
                            <option key={initiative.id} value={initiative.id}>{initiative.name}</option>
                          ))}
                        </select>
                        {offering.status !== "draft" ? <span className="mt-1 block text-xs text-ink-3">{t("initiativeDraftOnly")}</span> : null}
                      </label>
                    ) : null}

                    {ruleMode === "applied" ? (
                      <InitiativeRulesPanel
                        mode="applied"
                        rules={ruleRead?.rules ?? null}
                        applied={{
                          depositEnabled: paymentMode === "deposit",
                          depositAmountCents: offering.depositAmountCents ?? null,
                          minAge: offering.minAge ?? null,
                          minParticipants: offering.minParticipants ?? null,
                          registrationDeadline: offering.registrationDeadline ?? null,
                        }}
                        startsAt={null}
                        locale={locale}
                      />
                    ) : null}

                    {/* #596 挂载前预览：选了尚未保存的 Initiative 即显示（挂载前可见规则）。
                        读面不可读/失败则整块不渲染——**有意的 fail-closed 静默降级**：
                        宁可什么都不说，也不把「读不到规则」误报成「没有规则」（无来源标签、
                        无错误块；施加态另有现值 + 通用提示的降级路径） */}
                    {ruleMode === "preview" && ruleRead?.status === "ok" ? (
                      <InitiativeRulesPanel
                        mode="preview"
                        rules={ruleRead.rules}
                        applied={null}
                        startsAt={fromLocalInput(activeDraft.startsAt)}
                        locale={locale}
                      />
                    ) : null}

                    {/* #624 解除挂载后仍留存的强制值：逐字段标出来源，场主改写并
                        保存该字段后该行消失（后端逐字段清除，保存响应带回新标记） */}
                    {kind === "event" && detachedProvenance ? (
                      <DetachedRuleProvenancePanel provenance={detachedProvenance} />
                    ) : null}

                    {/* #624 报名门槛（仅 event）：挂载锁死/挂载预览时禁用；解除挂载后
                        回归普通可编辑字段（方案 C 的核心：值保留、可改、来源标记随首次
                        改写消失） */}
                    {kind === "event" ? (
                      <fieldset className="grid gap-3">
                        <legend className="text-[13px] text-ink-3">
                          {t("eventThresholdsTitle")}
                        </legend>
                        <label
                          className="block"
                          data-state={thresholdsLocked(minAgeLocked)}
                        >
                          <span className="block text-[13px] text-ink-3">
                            {t("minAgeLabel")}
                          </span>
                          <input
                            type="number"
                            min={1}
                            data-testid="event-min-age-input"
                            value={activeDraft.minAge}
                            placeholder={t("minAgePlaceholder")}
                            disabled={thresholdsLocked(minAgeLocked) !== "editable"}
                            onChange={(e) =>
                              setMetaDraft({ ...activeDraft, minAge: e.target.value })
                            }
                            className="ui-input mt-1 w-full"
                          />
                        </label>
                        <label
                          className="block"
                          data-state={thresholdsLocked(minParticipantsLocked)}
                        >
                          <span className="block text-[13px] text-ink-3">
                            {t("minParticipantsLabel")}
                          </span>
                          <input
                            type="number"
                            min={1}
                            data-testid="event-min-participants-input"
                            value={activeDraft.minParticipants}
                            placeholder={t("minParticipantsPlaceholder")}
                            disabled={
                              thresholdsLocked(minParticipantsLocked) !== "editable"
                            }
                            onChange={(e) =>
                              setMetaDraft({
                                ...activeDraft,
                                minParticipants: e.target.value,
                              })
                            }
                            className="ui-input mt-1 w-full"
                          />
                        </label>
                        <span className="block text-xs text-ink-3">
                          {t("eventThresholdsHint")}
                        </span>
                      </fieldset>
                    ) : null}

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
                          data-testid="curriculum-requirements-input"
                          rows={4}
                          value={activeDraft.curriculumRequirements}
                          onChange={(e) =>
                            setMetaDraft({
                              ...activeDraft,
                              curriculumRequirements: e.target.value,
                            })
                          }
                          className="ui-textarea mt-1 w-full"
                          placeholder={t("researchPlaceholder")}
                        />
                      </label>
                    ) : null}

                    {/* 缴费槽（U9/KTD10/R1/R3）：三态单选 + 押金金额；挂载 Initiative
                        的场押金只读并提示来源（与规则摘要块合并为单一缴费槽展示） */}
                    <PaymentSlotFields
                      kind={kind}
                      mode={activeDraft.mode}
                      onModeChange={(mode) => {
                        setMetaDraft({ ...activeDraft, mode });
                        setSaveMessage(null);
                      }}
                      tierDrafts={activeDraft.tierDrafts}
                      onTierDraftsChange={(tierDrafts) =>
                        setMetaDraft({ ...activeDraft, tierDrafts })
                      }
                      depositAmount={activeDraft.depositAmount}
                      onDepositAmountChange={(depositAmount) =>
                        setMetaDraft({ ...activeDraft, depositAmount })
                      }
                      depositDisabled={initiativeGovernsDeposit}
                      modeDisabled={paymentSlotLocked}
                      sourceNote={paymentSlotSource}
                    />

                    {activeDraft.mode === "pricing" &&
                    soldTierTouched.length > 0 ? (
                      <p
                        role="alert"
                        className="text-[13px] text-amber-200"
                        data-testid="sold-tier-warning"
                      >
                        {t("guardSoldTier")}
                      </p>
                    ) : null}

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

              {/* U7（R12–R14）：主理人管理；Owner/Admin 随时可增删 */}
              {manage && kind === "event" && offering ? (
                <EventModeratorsCard
                  workspaceId={offering.workspaceId ?? ws?.id ?? ""}
                  eventId={offering.id}
                  workspaceSlug={slug}
                />
              ) : null}
            </div>

            {/* E-5 #50 G3：工作台详情页报名入口（本人无既有报名；复用
						    submitEnrollment，鉴权后端管）。P1-5：卡片渲染不再以
						    open 为门——课程关闭后已报名状态仍可见；open 只约束
						    「报名操作」分支（非 open 显示报名已关闭）。#575 后报名
						    操作另受派生 enrollmentBadge 门（已满/已截止不出表单）。 */}
            {!wsLoading &&
            ws &&
            !readOnlyVisitor &&
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
                      ) : submitState.kind === "confirmed" ? (
                        enrollmentFollowUp()
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
                    <div className="grid gap-2">
                      <p className="text-[13px] text-ink-3">
                        {t("pendingApproval", { label: labelsT(label) })}
                      </p>
                      {enrollState.enrollment.approvalDeadline ? (
                        <p className="text-[13px] text-ink-3">
                          {t("approvalDeadline", {
                            time: formatDeadline(
                              enrollState.enrollment.approvalDeadline,
                              tCommon("timeTbd"),
                              locale,
                            ),
                          })}
                        </p>
                      ) : null}
                      <Link
                        href="/participations"
                        className="justify-self-start text-[13px] text-accent hover:underline"
                      >
                        {t("viewInParticipations")}
                      </Link>
                    </div>
                  ) : enrollState.enrollment ? (
                    <div className="grid gap-2">
                      <p className="text-[13px] text-ink-3">
                        {t("enrolled", { label: labelsT(label) })}
                      </p>
                      {enrollmentFollowUp()}
                    </div>
                  ) : offering.status !== "open" ? (
                    <p className="text-[13px] text-ink-3">{t("enrollClosed")}</p>
                  ) : offering.enrollmentBadge === "full" ||
                    offering.enrollmentBadge === "closed" ? (
                    /* #575：与公开页同构的第二道门——status=open 但派生 badge 已
                       full（占满）/closed（截止）时不出表单，堵「填完才被后端拒」死路 */
                    <p
                      className="text-[13px] text-ink-3"
                      data-testid="enrollment-badge-gate"
                    >
                      {offering.enrollmentBadge === "full"
                        ? t("enrollFull")
                        : t("enrollDeadlinePassed")}
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
                                  effectiveTierId === tier.id
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
                                    checked={effectiveTierId === tier.id}
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
                            // R11：取消有收款面的活动明示自动退款笔数与总金额
                            // （押金场 pricingEnabled=false，同属收款面 → 一并加载）
                            if (
                              tr === "cancel" &&
                              (offering.pricingEnabled === true || offering.depositEnabled === true)
                            ) {
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
                        sponsorshipTiers: tiers.map(serializeSponsorshipTier),
                      });
                      if (res.result) {
                        setState({
                          id: offering.id,
                          row: {
                            ...offering,
                            sponsorshipTiers: tiers.map(serializeSponsorshipTier),
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
                depositEnabled={offering.depositEnabled === true}
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
  const locale = useLocale();
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
  const [initiativeId, setInitiativeId] = useState<string | null>(null);
  const [initiatives, setInitiatives] = useState<PublicInitiativeCard[]>([]);
  // 缴费槽（U9/KTD10/R1）：默认免费收起（AE4 免费路径零额外操作）；三态互斥，
  // 定价态至少一档（对齐后端 PriceTiersValidation），押金态正金额 + ends_at
  // （对齐后端 PaymentModeValidation）。
  const [mode, setMode] = useState<PaymentMode>("free");
  const [depositAmount, setDepositAmount] = useState("");
  const [tierDrafts, setTierDrafts] = useState<TierDraft[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadInitiatives = () => {
    if (initiatives.length > 0 || kind !== "event") return;
    void fetchPublicInitiatives()
      .then((rows) => setInitiatives(rows.filter((row) => row.status === "open")))
      .catch(() => setInitiatives([]));
  };

  // 新建页无需只读门（无既有 Initiative 规则物化；挂载后由编辑页呈现来源），
  // 但挂载前预览（#596）同样要在保存前可见——见下方 ruleRead
  const translatePaymentError = usePaymentErrorTranslator();

  const manage = ws ? canManageEvents(ws.myAbilities) : false;
  const ruleRead = useInitiativeMountPreview(ws?.id, initiativeId, manage && kind === "event");
  const label = OFFERING_LABEL[kind];
  const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;
  async function submit() {
    if (!ws) return;
    // venue all-or-none：任一填写则四键须齐全，否则就地拦截不提交（KTD5）
    if (kind === "event" && venueDraftIncomplete(venue)) {
      setError(t("venueIncomplete"));
      return;
    }
    // 定价态：至少一档有效（PriceTiersValidation 前端先拦，后端兜底）；
    // 档位草稿仅在定价态参与校验（切押金/免费时随 payload 清空）
    const validTiers = tierDrafts.map(fromDraft).filter((x) => x !== null);
    if (mode === "pricing" && validTiers.length === 0) {
      setError(t("pricingTierRequired"));
      return;
    }
    // 押金态：正金额 + ends_at 结算锚点 + 报名截止（自助取消锚点，B② 后端同款判据）
    const depositCents = depositAmountToCents(depositAmount);
    if (mode === "deposit") {
      if (depositCents === null) {
        setError(t("depositAmountRequired"));
        return;
      }
      if (endsAt.trim() === "") {
        setError(t("depositEndsAtRequired"));
        return;
      }
      if (deadline.trim() === "") {
        setError(t("depositDeadlineRequired"));
        return;
      }
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
        ...(kind === "event" && initiativeId ? { initiativeId } : {}),
        // 免费路径不下发缴费键（后端默认免费）；其余三态键由单源序列化产出
        // （三态互斥：押金态清档位、定价态清押金）
        ...(mode === "free"
          ? {}
          : paymentSlotPayload({
              kind,
              mode,
              tiers: validTiers.map((tier) => JSON.stringify(tier)),
              depositAmountCents: depositCents,
            })),
      });
      if (res.result) {
        router.push(`${base}/${res.result.id}`);
      } else {
        setError(
          offeringErrorText(
            res.errors[0],
            "createFailed",
            t,
            translatePaymentError,
          ),
        );
      }
    } catch (e: unknown) {
      setError(
        offeringErrorText(
          e instanceof Error ? { message: e.message } : null,
          "createFailed",
          t,
          translatePaymentError,
        ),
      );
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

        <div className="mt-8 max-w-xl rounded-large border border-line bg-card p-6">
          <div className="grid gap-4">
            <label className="block">
              <span className="block text-[13px] text-ink-3">
                {t("titleRequired")}
              </span>
              <input
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                className="ui-input mt-1 w-full"
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
                className="ui-select mt-1 w-full"
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
                className="ui-input mt-1 w-full"
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
                className="ui-input mt-1 w-full"
              />
            </label>

            <ScheduleFields
              startsAt={startsAt}
              endsAt={endsAt}
              onStartsAtChange={setStartsAt}
              onEndsAtChange={setEndsAt}
            />

            {kind === "event" ? (
              <label className="block">
                <span className="block text-[13px] text-ink-3">{t("initiativeLabel")}</span>
                <select
                  value={initiativeId ?? ""}
                  onFocus={loadInitiatives}
                  onChange={(e) => setInitiativeId(e.target.value || null)}
                  className="ui-select mt-1 w-full"
                >
                  <option value="">{t("initiativeNone")}</option>
                  {initiatives.map((initiative) => (
                    <option key={initiative.id} value={initiative.id}>{initiative.name}</option>
                  ))}
                </select>
              </label>
            ) : null}

            {/* #596 挂载前预览：选中即显示规则（保存即挂载）；读面不可读/失败整块不渲染 */}
            {kind === "event" && ruleRead?.status === "ok" ? (
              <InitiativeRulesPanel
                mode="preview"
                rules={ruleRead.rules}
                applied={null}
                startsAt={fromLocalInput(startsAt)}
                locale={locale}
              />
            ) : null}

            {kind === "event" ? (
              <VenueFields value={venue} onChange={setVenue} />
            ) : null}

            {/* 缴费槽（U9/KTD10/R1）：默认免费收起（AE4 免费路径零额外操作），
                展开后三态单选 + 押金金额/档位编辑 */}
            <details
              className="rounded-large border border-line bg-soft-2/40 p-4"
              data-testid="pricing-section"
            >
              <summary className="cursor-pointer text-sm font-medium text-ink">
                {t("paymentSlotTitle")}
              </summary>
              <div className="mt-3 grid gap-3">
                <p className="text-[13px] text-ink-3">{t("paymentSlotHint")}</p>
                <PaymentSlotFields
                  kind={kind}
                  mode={mode}
                  onModeChange={(next) => {
                    setMode(next);
                    setError(null);
                  }}
                  tierDrafts={tierDrafts}
                  onTierDraftsChange={setTierDrafts}
                  depositAmount={depositAmount}
                  onDepositAmountChange={setDepositAmount}
                />
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
