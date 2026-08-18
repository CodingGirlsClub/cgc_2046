"use client";

import Link from "next/link";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { useQuery } from "@apollo/client/react";
import { useSearchParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import { useAuthed } from "@/lib/use-authed";
import LearningTab, {
  ParticipationsTabs,
} from "@/components/learning/learning-tab";
import {
  CANCEL_ENROLLMENT,
  ENROLLMENT_STATUS_LABEL,
  MY_ENROLLMENTS,
  MY_LEARNING_RUNS,
  MY_SPONSORSHIPS,
  SPONSORSHIP_STATUS_LABEL,
  type KeysetPage,
  type ParticipationEnrollment,
  type ParticipationSponsorship,
} from "@/lib/graphql/participations";

const PAGE_SIZE = 20;

function mergeKeysetPage<T extends { id: string }>(
  previous: KeysetPage<T>,
  next: KeysetPage<T>,
): KeysetPage<T> {
  const rows = new Map<string, T>();
  for (const row of [...previous.results, ...next.results])
    rows.set(row.id, row);
  return {
    ...next,
    count: next.count ?? previous.count,
    results: [...rows.values()],
  };
}

function formatDateTime(value: string | null | undefined): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function ErrorNotice({ children }: { children: React.ReactNode }) {
  return (
    <div
      role="alert"
      className="rounded-large border border-red-400/30 bg-red-500/10 px-4 py-3 text-sm text-red-300"
    >
      {children}
    </div>
  );
}

function EnrollmentCard({
  row,
  confirming,
  busy,
  onRequestCancel,
  onConfirmCancel,
  onKeep,
}: {
  row: ParticipationEnrollment;
  confirming: boolean;
  busy: boolean;
  onRequestCancel: () => void;
  onConfirmCancel: () => void;
  onKeep: () => void;
}) {
  const t = useTranslations("participations");
  const canCancel =
    row.status === "pending" ||
    row.status === "payment_pending" ||
    row.status === "confirmed";
  return (
    <article
      className="rounded-large border border-line bg-card p-4"
      data-testid={`enrollment-${row.id}`}
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="font-medium text-ink">
            {row.targetTitle ?? t("enrollmentFallback")}
          </h3>
          <p className="mt-1 text-xs text-ink-3">
            {row.eventId ? t("kindEvent") : t("kindCourse")} ·{" "}
            {t("enrolledAt", { time: formatDateTime(row.insertedAt) })}
          </p>
        </div>
        <span className="rounded-full border border-line-strong px-2.5 py-1 text-xs text-ink-2">
          {ENROLLMENT_STATUS_LABEL[row.status]}
        </span>
      </div>

      {row.status === "payment_pending" ? (
        <div className="mt-3 flex flex-wrap items-center gap-3">
          <Link
            href={`/orders/new?enrollmentId=${row.id}`}
            className="rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line"
            data-testid={`pay-entry-${row.id}`}
          >
            {t("goPay")}
          </Link>
          <span className="text-[13px] text-ink-3">{t("slotReserved")}</span>
        </div>
      ) : null}
      {row.status === "pending" && row.approvalDeadline ? (
        <p className="mt-3 text-sm text-amber-300">
          {t("approvalDeadline", { time: formatDateTime(row.approvalDeadline) })}
        </p>
      ) : null}
      {row.rejectionReason ? (
        <p className="mt-3 text-sm text-red-300">
          {t("rejectionReason", { reason: row.rejectionReason })}
        </p>
      ) : null}
      {row.status === "expired" && row.expiredAt ? (
        <p className="mt-3 text-sm text-ink-3">
          {t("expiredAt", { time: formatDateTime(row.expiredAt) })}
        </p>
      ) : null}
      {row.status === "cancelled" && row.cancelledAt ? (
        <p className="mt-3 text-sm text-ink-3">
          {t("cancelledAt", { time: formatDateTime(row.cancelledAt) })}
        </p>
      ) : null}

      {canCancel ? (
        <div className="mt-4">
          {confirming ? (
            <div
              className="rounded-large border border-amber-400/30 bg-amber-500/10 p-3"
              role="group"
              aria-label={t("cancelGroupAria")}
            >
              <p className="text-sm text-amber-200">{t("cancelConfirm")}</p>
              <div className="mt-3 flex flex-wrap gap-2">
                <button
                  type="button"
                  className="join-button join-button--primary"
                  disabled={busy}
                  onClick={onConfirmCancel}
                >
                  {busy ? t("cancelling") : t("confirmCancel")}
                </button>
                <button
                  type="button"
                  className="join-button"
                  disabled={busy}
                  onClick={onKeep}
                >
                  {t("keepEnrollment")}
                </button>
              </div>
            </div>
          ) : (
            <button
              type="button"
              className="join-button"
              onClick={onRequestCancel}
            >
              {t("cancelEnrollment")}
            </button>
          )}
        </div>
      ) : null}
    </article>
  );
}

function SponsorshipCard({ row }: { row: ParticipationSponsorship }) {
  const t = useTranslations("participations");
  return (
    <article
      className="rounded-large border border-line bg-card p-4"
      data-testid={`sponsorship-${row.id}`}
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="font-medium text-ink">
            {row.targetTitle ?? t("sponsorshipFallback")}
          </h3>
          <p className="mt-1 text-xs text-ink-3">
            {row.level === "workspace" ? t("sponsorshipWorkspace") : t("sponsorshipEvent")}
            {row.tierName ? ` · ${row.tierName}` : ""}
          </p>
        </div>
        <span className="rounded-full border border-line-strong px-2.5 py-1 text-xs text-ink-2">
          {SPONSORSHIP_STATUS_LABEL[row.status]}
        </span>
      </div>
      {row.amount != null ? (
        <p className="mt-3 text-sm text-ink-2">
          {t("intentAmount", { amount: row.amount })}
        </p>
      ) : null}
      {row.approvedAt ? (
        <p className="mt-2 text-xs text-ink-3">
          {t("approvedAt", { time: formatDateTime(row.approvedAt) })}
        </p>
      ) : null}
      {row.rejectionReason ? (
        <p className="mt-2 text-sm text-red-300">
          {t("rejectionReason", { reason: row.rejectionReason })}
        </p>
      ) : null}
      {row.endedAt ? (
        <p className="mt-2 text-xs text-ink-3">
          {t("endedAt", { time: formatDateTime(row.endedAt) })}
        </p>
      ) : null}
      {row.deliveries.length > 0 ? (
        <div className="mt-4 border-t border-line pt-3">
          <h4 className="text-sm font-medium text-ink-2">
            {t("deliveryTitle")}
          </h4>
          <ul className="mt-2 grid gap-2">
            {row.deliveries.map((delivery) => (
              <li
                key={`${row.id}-${delivery.benefit}`}
                className="flex flex-wrap items-center justify-between gap-2 text-sm"
              >
                <span className="text-ink-2">{delivery.benefit}</span>
                <span
                  className={
                    delivery.fulfilledAt ? "text-emerald-300" : "text-amber-300"
                  }
                >
                  {delivery.fulfilledAt
                    ? t("deliveryDone")
                    : t("deliveryPending", {
                        time: delivery.dueDate
                          ? ` · ${formatDateTime(delivery.dueDate)}`
                          : "",
                      })}
                </span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </article>
  );
}

export default function ParticipationsPage() {
  const router = useRouter();
  const t = useTranslations("participations");
  const { authed, confirmed } = useAuthed();
  const enrollmentQuery = useQuery(MY_ENROLLMENTS, {
    variables: { first: PAGE_SIZE },
    skip: !authed,
    notifyOnNetworkStatusChange: true,
  });
  const sponsorshipQuery = useQuery(MY_SPONSORSHIPS, {
    variables: { first: PAGE_SIZE },
    skip: !authed,
    notifyOnNetworkStatusChange: true,
  });
  const learningQuery = useQuery(MY_LEARNING_RUNS, {
    skip: !authed,
    notifyOnNetworkStatusChange: true,
  });

  const [confirmingId, setConfirmingId] = useState<string | null>(null);
  const [cancellingId, setCancellingId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [enrollmentLoadingMore, setEnrollmentLoadingMore] = useState(false);
  const [sponsorshipLoadingMore, setSponsorshipLoadingMore] = useState(false);

  const enrollmentPage = enrollmentQuery.data?.myEnrollments;
  const sponsorshipPage = sponsorshipQuery.data?.mySponsorships;
  const enrollmentRows = enrollmentPage?.results ?? [];
  const sponsorshipRows = sponsorshipPage?.results ?? [];
  const activeEnrollments = enrollmentRows.filter(
    (row) =>
      row.status === "pending" ||
      row.status === "payment_pending" ||
      row.status === "confirmed",
  );
  const endedEnrollments = enrollmentRows.filter(
    (row) =>
      row.status === "rejected" ||
      row.status === "expired" ||
      row.status === "cancelled",
  );
  const hasMoreEnrollments = enrollmentPage
    ? enrollmentPage.count == null
      ? Boolean(enrollmentPage.endKeyset)
      : enrollmentRows.length < enrollmentPage.count
    : false;
  const hasMoreSponsorships = sponsorshipPage
    ? sponsorshipPage.count == null
      ? Boolean(sponsorshipPage.endKeyset)
      : sponsorshipRows.length < sponsorshipPage.count
    : false;

  async function loadMoreEnrollments() {
    if (
      !enrollmentPage?.endKeyset ||
      !hasMoreEnrollments ||
      enrollmentLoadingMore
    )
      return;
    setEnrollmentLoadingMore(true);
    try {
      await enrollmentQuery.fetchMore({
        variables: { first: PAGE_SIZE, after: enrollmentPage.endKeyset },
        updateQuery: (previous, { fetchMoreResult }) => {
          if (!fetchMoreResult) return previous;
          return {
            myEnrollments: mergeKeysetPage(
              previous.myEnrollments,
              fetchMoreResult.myEnrollments,
            ),
          };
        },
      });
    } catch {
      setActionError(t("loadEnrollFailed"));
    } finally {
      setEnrollmentLoadingMore(false);
    }
  }

  async function loadMoreSponsorships() {
    if (
      !sponsorshipPage?.endKeyset ||
      !hasMoreSponsorships ||
      sponsorshipLoadingMore
    )
      return;
    setSponsorshipLoadingMore(true);
    try {
      await sponsorshipQuery.fetchMore({
        variables: { first: PAGE_SIZE, after: sponsorshipPage.endKeyset },
        updateQuery: (previous, { fetchMoreResult }) => {
          if (!fetchMoreResult) return previous;
          return {
            mySponsorships: mergeKeysetPage(
              previous.mySponsorships,
              fetchMoreResult.mySponsorships,
            ),
          };
        },
      });
    } catch {
      setActionError(t("loadSponsorFailed"));
    } finally {
      setSponsorshipLoadingMore(false);
    }
  }

  async function cancelEnrollment(row: ParticipationEnrollment) {
    setCancellingId(row.id);
    setActionError(null);
    try {
      const response = await client.mutate({
        mutation: CANCEL_ENROLLMENT,
        variables: { id: row.id },
      });
      const payload = response.data?.cancelEnrollment;
      const alreadyProcessed = payload?.errors?.some(
        (error) => error.code === "enrollment_already_processed",
      );
      if (!payload?.result && !alreadyProcessed) {
        throw new Error(
          payload?.errors?.[0]?.message ?? t("cancelFailed"),
        );
      }
      await enrollmentQuery.refetch();
      setConfirmingId(null);
    } catch (error: unknown) {
      setActionError(error instanceof Error ? error.message : t("cancelFailed"));
    } finally {
      setCancellingId(null);
    }
  }

  // U8(R11):学习/报名/赞助子导航,学习默认 tab(?tab= 切换;tab 状态由
  // URL 承载——切 tab 保留组件状态的同页分组数据在三个 query 中常驻)
  const searchParams = useSearchParams();
  const tabParam = searchParams.get("tab");
  const tab: "learning" | "enrollments" | "sponsorships" =
    tabParam === "enrollments" || tabParam === "sponsorships"
      ? tabParam
      : "learning";

  const learningRuns = (learningQuery.data?.myLearningRuns ?? []).slice();

  if (!confirmed) {
    return (
      <main className="ws-shell-loading">
        <span>{t("confirming")}</span>
      </main>
    );
  }
  if (!authed) {
    router.replace(`/login?next=${encodeURIComponent("/participations")}`);
    return null;
  }

  return (
    <main className="mx-auto w-full max-w-5xl px-4 py-10">
      <header className="mb-6">
        <p className="text-[13px] text-ink-3">
          <Link href="/" className="hover:text-ink">
            {t("breadcrumbHome")}
          </Link>{" "}
          › {t("title")}
        </p>
        <h1 className="mt-3 text-3xl font-semibold text-ink">{t("title")}</h1>
        <p className="mt-2 text-sm text-ink-3">{t("subtitle")}</p>
      </header>

      <ParticipationsTabs tab={tab} />

      {actionError ? (
        <div className="mt-5">
          <ErrorNotice>{actionError}</ErrorNotice>
        </div>
      ) : null}

      <div className="mt-6 grid gap-6" data-testid={`panel-${tab}`}>
        {tab === "enrollments" ? (
          <section
            aria-labelledby="participations-enrollments"
            className="rounded-large border border-line bg-view p-5"
          >
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <div>
                <h2
                  id="participations-enrollments"
                  className="text-xl font-semibold text-ink"
                >
                  {t("enrollmentsTitle")}
                </h2>
                <p className="mt-1 text-sm text-ink-3">
                  {t("enrollmentsDesc")}
                </p>
              </div>
              <Link
                href="/events"
                className="text-sm text-accent hover:underline"
              >
                {t("discoverEvents")}
              </Link>
            </div>
            {enrollmentQuery.loading && !enrollmentPage ? (
              <p className="mt-5 text-sm text-ink-3">{t("loading")}</p>
            ) : null}
            {enrollmentQuery.error ? (
              <div className="mt-5">
                <ErrorNotice>{t("enrollLoadError")}</ErrorNotice>
              </div>
            ) : null}
            {!enrollmentQuery.loading && !enrollmentQuery.error ? (
              <div className="mt-5 grid gap-5">
                <div>
                  <h3 className="text-sm font-medium text-ink-2">
                    {t("activeSection")}
                  </h3>
                  {activeEnrollments.length === 0 ? (
                    <p className="mt-2 text-sm text-ink-3">
                      {t("noActive")}
                    </p>
                  ) : (
                    <div className="mt-2 grid gap-3">
                      {activeEnrollments.map((row) => (
                        <EnrollmentCard
                          key={row.id}
                          row={row}
                          confirming={confirmingId === row.id}
                          busy={cancellingId === row.id}
                          onRequestCancel={() => setConfirmingId(row.id)}
                          onConfirmCancel={() => void cancelEnrollment(row)}
                          onKeep={() => setConfirmingId(null)}
                        />
                      ))}
                    </div>
                  )}
                </div>
                <div>
                  <h3 className="text-sm font-medium text-ink-2">
                    {t("endedSection")}
                  </h3>
                  {endedEnrollments.length === 0 ? (
                    <p className="mt-2 text-sm text-ink-3">
                      {t("noEnded")}
                    </p>
                  ) : (
                    <div className="mt-2 grid gap-3">
                      {endedEnrollments.map((row) => (
                        <EnrollmentCard
                          key={row.id}
                          row={row}
                          confirming={false}
                          busy={false}
                          onRequestCancel={() => undefined}
                          onConfirmCancel={() => undefined}
                          onKeep={() => undefined}
                        />
                      ))}
                    </div>
                  )}
                </div>
                {hasMoreEnrollments ? (
                  <button
                    type="button"
                    className="join-button justify-self-center"
                    disabled={enrollmentLoadingMore}
                    onClick={() => void loadMoreEnrollments()}
                  >
                    {enrollmentLoadingMore ? t("loading") : t("loadMore")}
                  </button>
                ) : null}
              </div>
            ) : null}
          </section>
        ) : null}

        {tab === "sponsorships" ? (
          <section
            aria-labelledby="participations-sponsorships"
            className="rounded-large border border-line bg-view p-5"
          >
            <h2
              id="participations-sponsorships"
              className="text-xl font-semibold text-ink"
            >
              {t("sponsorshipsTitle")}
            </h2>
            <p className="mt-1 text-sm text-ink-3">
              {t("sponsorshipsDesc")}
            </p>
            {sponsorshipQuery.loading && !sponsorshipPage ? (
              <p className="mt-5 text-sm text-ink-3">{t("loading")}</p>
            ) : null}
            {sponsorshipQuery.error ? (
              <div className="mt-5">
                <ErrorNotice>{t("sponsorLoadError")}</ErrorNotice>
              </div>
            ) : null}
            {!sponsorshipQuery.loading && !sponsorshipQuery.error ? (
              sponsorshipRows.length === 0 ? (
                <p className="mt-5 text-sm text-ink-3">
                  {t("noSponsorships")}
                </p>
              ) : (
                <div className="mt-5 grid gap-3">
                  {sponsorshipRows.map((row) => (
                    <SponsorshipCard key={row.id} row={row} />
                  ))}
                  {hasMoreSponsorships ? (
                    <button
                      type="button"
                      className="join-button justify-self-center"
                      disabled={sponsorshipLoadingMore}
                      onClick={() => void loadMoreSponsorships()}
                    >
                      {sponsorshipLoadingMore ? t("loading") : t("loadMore")}
                    </button>
                  ) : null}
                </div>
              )
            ) : null}
          </section>
        ) : null}

        {tab === "learning" ? (
          <section
            aria-labelledby="participations-learning"
            className="rounded-large border border-line bg-view p-5"
          >
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <div>
                <h2
                  id="participations-learning"
                  className="text-xl font-semibold text-ink"
                >
                  {t("learningTitle")}
                </h2>
                <p className="mt-1 text-sm text-ink-3">
                  {t("learningDesc")}
                </p>
              </div>
            </div>
            {learningQuery.loading ? (
              <p className="mt-5 text-sm text-ink-3">{t("loading")}</p>
            ) : null}
            {learningQuery.error ? (
              <div className="mt-5">
                <ErrorNotice>{t("learningLoadError")}</ErrorNotice>
              </div>
            ) : null}
            {!learningQuery.loading && !learningQuery.error ? (
              <LearningTab runs={learningRuns} />
            ) : null}
          </section>
        ) : null}
      </div>
    </main>
  );
}
