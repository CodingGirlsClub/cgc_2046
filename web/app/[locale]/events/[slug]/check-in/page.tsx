"use client";

/**
 * 现场核销页 /events/[slug]/check-in（押金制 KTD5/KTD10；R6、R11；#508 最小核销集）。
 *
 * 站点壳落地页（工作台壳之外，会场里任何有主理人身份的账号都能开）：扫码或手输
 * 6 位核销码 → 后端生成 Attendance 记录，并在同事务内发起押金全额退还
 * （KTD6 核销即退，参与者当场收到「押金已退」）。
 *
 * - 未登录先登录：`?next=` 回带本页完整 URL（含 code），登录后落回原提交面；
 * - URL `?code=` 预填为扫码方式；本地格式校验不过不发 mutation（空码 / 非 6 位数字）；
 * - 授权与业务判定全在后端（KTD4）：成功 / 已核销 / 押金已结算 / 码无效 / 无权限
 *   全按后端 code 出文案（messages errors namespace），网络类故障可原样重试；
 * - URL 路段既可是公开 slug（主理人链接由 offering-pages 复制），也可是 event id
 *   （参与者二维码：/participations 报名行只有 eventId），见 lib/check-in 解析。
 */

import { Suspense, useEffect, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams, useSearchParams } from "next/navigation";
import { useLocale, useTranslations } from "next-intl";
import { useAuthed } from "@/lib/auth-provider";
import { formatDeadline } from "@/lib/events";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import {
  checkInEnrollment,
  normalizeCheckInCode,
  resolveCheckInEvent,
  type CheckInEventRef,
} from "@/lib/check-in";
import type { CheckInAttendance, CheckInMethod } from "@/lib/graphql/attendance";
import SitePage from "@/components/site-page";

type EventState = {
  /** 已解析的路段（stale 守卫：路段切换时旧结果自动失效） */
  id: string;
  status: "loading" | "ok" | "missing" | "error";
  ref: CheckInEventRef | null;
};

type Feedback =
  | { kind: "success"; attendance: CheckInAttendance }
  | { kind: "error"; message: string }
  | null;

export default function Page() {
  return (
    <SitePage>
      <div className="mx-auto w-full max-w-3xl px-4 py-10">
        <Suspense
          fallback={
            <div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
          }
        >
          <CheckInPanel />
        </Suspense>
      </div>
    </SitePage>
  );
}

function CheckInPanel() {
  const t = useTranslations("checkIn");
  const tCommon = useTranslations("common");
  const translatePaymentError = usePaymentErrorTranslator();
  const locale = useLocale();
  const params = useParams<{ slug: string }>();
  const searchParams = useSearchParams();
  const segment = params?.slug ?? "";
  const { authed } = useAuthed();

  // URL 预填（KTD5：扫码 URL 带码）。格式非法只提示、不预填垃圾值。
  const urlCodeRaw = searchParams?.get("code") ?? "";
  const urlCode = normalizeCheckInCode(urlCodeRaw);

  const [codeState, setCodeState] = useState<{
    value: string;
    method: CheckInMethod;
  }>({ value: urlCode ?? "", method: urlCode ? "scan" : "manual" });
  const [hint, setHint] = useState<string | null>(
    urlCodeRaw && !urlCode ? t("invalidCodeInUrl") : null,
  );
  const [phase, setPhase] = useState<"idle" | "submitting">("idle");
  const [feedback, setFeedback] = useState<Feedback>(null);
  const [eventState, setEventState] = useState<EventState>({
    id: "",
    status: "loading",
    ref: null,
  });
  // 解析失败重试（网络类）：nonce 触发 effect 重跑
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    if (!segment) return;
    let cancelled = false;

    resolveCheckInEvent(segment)
      .then((ref) => {
        if (!cancelled) {
          setEventState({
            id: segment,
            status: ref ? "ok" : "missing",
            ref,
          });
        }
      })
      .catch(() => {
        if (!cancelled) {
          setEventState({ id: segment, status: "error", ref: null });
        }
      });

    return () => {
      cancelled = true;
    };
  }, [segment, nonce]);

  const stale = eventState.id !== segment;
  const eventRef = !stale && eventState.status === "ok" ? eventState.ref : null;
  const loadStatus = !segment
    ? "missing"
    : stale
      ? "loading"
      : eventState.status;

  async function submit() {
    const eventId = eventRef?.id ?? null;
    const normalized = normalizeCheckInCode(codeState.value);
    if (!normalized) {
      // 本地拦截：空码 / 非 6 位数字不发 mutation（后端只回「码无效」，前端能更准）
      setFeedback(null);
      setHint(t(codeState.value.trim() === "" ? "codeRequired" : "codeFormat"));
      return;
    }
    if (!eventId || phase === "submitting") return;

    setHint(null);
    setFeedback(null);
    setPhase("submitting");
    try {
      const res = await checkInEnrollment({
        eventId,
        code: normalized,
        method: codeState.method,
      });
      if (res.result) {
        // 码留在输入框：同码再提交由后端回「已核销」（防重复核销的现场确认）
        setFeedback({ kind: "success", attendance: res.result });
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

  // 登录/注册回带本页（含 URL 里的码），登录后直接落回提交面
  const nextPath = `/events/${segment}/check-in${urlCodeRaw ? `?code=${urlCodeRaw}` : ""}`;
  const loginHref = `/login?next=${encodeURIComponent(nextPath)}`;

  return (
    <>
      <header className="mb-6">
        <p className="text-[13px] text-ink-3">
          <Link href="/" className="hover:text-ink">
            {t("breadcrumbHome")}
          </Link>
          {" › "}
          <Link href="/events" className="hover:text-ink">
            {t("breadcrumbEvents")}
          </Link>
          {" › "}
          <strong>{t("title")}</strong>
        </p>
      </header>

      {loadStatus === "loading" ? (
        <div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
      ) : loadStatus === "missing" ? (
        <div className="join-card text-center" role="alert">
          <h1 className="text-lg font-medium">{t("missingTitle")}</h1>
          <p className="mt-2 text-sm text-ink-3">{t("missingDesc")}</p>
          <Link
            href="/events"
            className="join-button join-button--primary mt-6 inline-block"
          >
            {t("browseEvents")}
          </Link>
        </div>
      ) : loadStatus === "error" ? (
        <div className="join-card text-center" role="alert">
          <h1 className="text-lg font-medium">{t("loadFailed")}</h1>
          <button
            type="button"
            onClick={() => setNonce((n) => n + 1)}
            className="join-button mt-6"
          >
            {tCommon("retry")}
          </button>
        </div>
      ) : (
        <div className="join-card !p-8" data-testid="check-in-panel">
          <p className="text-[13px] text-ink-3">{t("subtitle")}</p>
          <h1 className="mt-3 text-2xl font-semibold">
            {eventRef?.title ?? t("titleFallback")}
          </h1>

          {!authed ? (
            <div className="mt-6 border-t border-line pt-5 text-sm">
              <Link
                href={loginHref}
                className="join-button join-button--primary inline-block"
              >
                {t("loginToCheckIn")}
              </Link>
              <p className="mt-2 text-[13px] text-ink-3">
                {t("noAccount")}{" "}
                <Link
                  href={`/register?next=${encodeURIComponent(nextPath)}`}
                  className="text-accent hover:underline"
                >
                  {t("registerAccount")}
                </Link>
                {t("loginHint")}
              </p>
            </div>
          ) : (
            <div className="mt-6 border-t border-line pt-5">
              <p className="text-[13px] text-ink-3">{t("onsiteHint")}</p>

              <label className="mt-4 block">
                <span className="block text-[13px] text-ink-3">
                  {t("codeField")}
                </span>
                <input
                  value={codeState.value}
                  onChange={(e) =>
                    setCodeState({ value: e.target.value, method: "manual" })
                  }
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
                  <p className="text-[13px] text-ink-3">
                    {t("successRefundNote")}
                  </p>
                </div>
              ) : null}
            </div>
          )}
        </div>
      )}
    </>
  );
}
