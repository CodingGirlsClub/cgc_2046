"use client";

/**
 * 现场核销页 /w/[slug]/events/[id]/check-in（#559：自站点壳迁入工作台壳）。
 *
 * 工作台壳内页面（#558 起主理人恒为成员）：未认证重定向与非成员「不可访问」
 * 由 WorkspaceShell 承担；event id 来自路由段，标题/押金旗标走成员读面
 * （成员可读 closed/成员可见活动——核销时刻活动通常已截止，这正是迁壳的
 * 理由）。手输 6 位核销码 → 后端生成 Attendance 记录，并在同事务内发起押金
 * 全额退还（KTD6 核销即退，参与者当场收到「押金已退」）。
 *
 * - 本地格式校验不过不发 mutation（空码 / 非 6 位数字）；
 * - 授权与业务判定全在后端（KTD4）：成功 / 已核销 / 押金已结算 / 码无效 / 无权限
 *   全按后端 code 出文案（messages errors namespace），网络类故障可原样重试；
 * - 场次读取只是展示增强：读失败用通用标题兜底，不阻断核销主流程。
 */

import { useEffect, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useLocale, useTranslations } from "next-intl";
import { formatDeadline } from "@/lib/events";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import {
  checkInEnrollment,
  fetchCheckInEvent,
  normalizeCheckInCode,
  type CheckInEventRef,
} from "@/lib/check-in";
import type { CheckInAttendance } from "@/lib/graphql/attendance";

type Feedback =
  | { kind: "success"; attendance: CheckInAttendance; depositRefund: string | null }
  | { kind: "error"; message: string }
  | null;

export default function Page() {
  const params = useParams<{ slug: string; id: string }>();
  const slug = params?.slug ?? "";
  const eventId = params?.id ?? "";

  return (
    <WorkspaceShell slug={slug}>
      <div className="ws-page-main__inner">
        {eventId ? (
          <CheckInPanel slug={slug} eventId={eventId} />
        ) : (
          <div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
        )}
      </div>
    </WorkspaceShell>
  );
}

function CheckInPanel({ slug, eventId }: { slug: string; eventId: string }) {
  const t = useTranslations("checkIn");
  const tCommon = useTranslations("common");
  const translatePaymentError = usePaymentErrorTranslator();
  const locale = useLocale();
  const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);

  const [code, setCode] = useState("");
  const [hint, setHint] = useState<string | null>(null);
  const [phase, setPhase] = useState<"idle" | "submitting">("idle");
  const [feedback, setFeedback] = useState<Feedback>(null);
  const [eventRef, setEventRef] = useState<CheckInEventRef | null>(null);
  const [eventLoading, setEventLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    // eventId 是路由段：变更即整页重挂载，无需在 effect 内同步重置 loading
    fetchCheckInEvent(eventId)
      .then((ref) => {
        if (!cancelled) setEventRef(ref);
      })
      .finally(() => {
        if (!cancelled) setEventLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [eventId]);

  async function submit() {
    const normalized = normalizeCheckInCode(code);
    if (!normalized) {
      // 本地拦截：空码 / 非 6 位数字不发 mutation（后端只回「码无效」，前端能更准）
      setFeedback(null);
      setHint(t(code.trim() === "" ? "codeRequired" : "codeFormat"));
      return;
    }
    if (phase === "submitting") return;

    setHint(null);
    setFeedback(null);
    setPhase("submitting");
    try {
      const res = await checkInEnrollment({
        eventId,
        code: normalized,
        // web 页是手输面（扫码主路径在小程序，#508-A）——method 恒 manual
        method: "manual",
      });
      if (res.enrollmentId != null) {
        // 码留在输入框：同码再提交由后端回「已核销」（防重复核销的现场确认）
        setFeedback({
          kind: "success",
          attendance: {
            enrollmentId: res.enrollmentId,
            checkedInAt: res.checkedInAt ?? "",
            method: res.method ?? "manual",
          },
          // 退款侧事实来自本次核销结果（不是「事件是不是押金场」）
          depositRefund: res.depositRefund ?? null,
        });
      } else {
        setFeedback({
          kind: "error",
          message: translatePaymentError(res.errors[0]?.code, t("failed")),
        });
      }
    } catch (e: unknown) {
      // 顶层 GraphQL 错误（未登录 / 会话过期）不带 payload code：按后端文案
      // 模式识别，其余（网络类）给可重试的通用文案，不透传英文原文
      const raw = e instanceof Error ? e.message : "";
      setFeedback({
        kind: "error",
        message: /unauthorized/i.test(raw)
          ? translatePaymentError("unauthorized", t("sessionExpired"))
          : t("networkFailed"),
      });
    } finally {
      setPhase("idle");
    }
  }

  return (
    <>
      <div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
        <Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
        <span>›</span>
        <Link href={`/w/${slug}/events/${eventId}`}>
          {eventRef?.title ?? t("titleFallback")}
        </Link>
        <span>›</span>
        <strong>{t("title")}</strong>
      </div>

      <header className="ws-page-heading">
        <div>
          <h1>{eventLoading ? t("titleFallback") : (eventRef?.title ?? t("titleFallback"))}</h1>
          <p>{t("subtitle")}</p>
        </div>
      </header>

      {wsLoading ? (
        <div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
      ) : (
        <div className="join-card !p-8" data-testid="check-in-panel">
          <p className="text-[13px] text-ink-3">{t("onsiteHint")}</p>

          <label className="mt-4 block">
            <span className="block text-[13px] text-ink-3">{t("codeField")}</span>
            <input
              value={code}
              onChange={(e) => setCode(e.target.value)}
              inputMode="numeric"
              autoComplete="one-time-code"
              // 上限留出分隔符余量（手输/粘贴「12 34 56」经归一剥掉空白后仍是 6 位）
              maxLength={9}
              placeholder={t("codePlaceholder")}
              className="ui-input mt-1 w-full max-w-[16rem] text-lg tracking-[0.2em]"
              data-testid="check-in-code-input"
            />
          </label>

          <div className="mt-4">
            <button
              type="button"
              disabled={phase === "submitting"}
              onClick={() => void submit()}
              className="join-button join-button--primary"
              data-testid="check-in-submit"
            >
              {phase === "submitting" ? t("submitting") : t("submit")}
            </button>
          </div>

          {hint ? (
            <p
              className="mt-3 text-[13px] text-amber-300"
              role="alert"
              data-testid="check-in-hint"
            >
              {hint}
            </p>
          ) : null}

          {feedback?.kind === "error" ? (
            <p
              className="mt-3 text-[13px] text-red-300"
              role="alert"
              data-testid="check-in-error"
            >
              {feedback.message}
            </p>
          ) : null}

          {feedback?.kind === "success" ? (
            <div
              className="mt-4 grid gap-1 rounded-large border border-line bg-soft-2 p-4 text-sm"
              role="status"
              data-testid="check-in-success"
            >
              <p className="font-medium text-accent">{t("successTitle")}</p>
              <p className="text-[13px] text-ink-3">
                {t("successDetail", {
                  time: formatDeadline(
                    feedback.attendance.checkedInAt,
                    tCommon("timeTbd"),
                    locale,
                  ),
                  method:
                    feedback.attendance.method === "scan"
                      ? t("methodScan")
                      : t("methodManual"),
                })}
              </p>
              {feedback.depositRefund === "forfeited" ? (
                <p className="text-[13px] text-ink-3">{t("successForfeitedNote")}</p>
              ) : feedback.depositRefund ? (
                <p className="text-[13px] text-ink-3">{t("successRefundNote")}</p>
              ) : null}
            </div>
          ) : null}
        </div>
      )}
    </>
  );
}
