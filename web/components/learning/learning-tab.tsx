"use client";

/**
 * 我的学习 tab(U8,R11):按课程分组 + issue 行(状态图标/key/标题/kind/n-m)
 * + 右侧抽屉(story 全文 + checklist 逐条 evidence + OpenClacky CTA)。
 *
 * 抽屉数据 = courseLearningDetail(U7,恒本人视角);打开时懒加载。
 * CTA 走 Rsk3 降级路径:复制学习任务指令文本,引导粘贴到 OpenClacky 会话。
 */

import Link from "next/link";
import { useEffect, useState } from "react";
import { createTranslator, useTranslations } from "next-intl";
import zhCN from "@/messages/zh-CN.json";
import { useQuery } from "@apollo/client/react";
import {
  COURSE_LEARNING_DETAIL,
  type CourseLearningDetail,
  type LearningIssue,
  type MyLearningRun,
} from "@/lib/graphql/participations";
import { LEARNING_RUN_STATUS_LABEL } from "@/lib/graphql/participations";
import {
  IssueKindChip,
  IssueStatusIcon,
  type IssueStatus,
} from "@/components/learning/issue-bits";

type Tab = "learning" | "enrollments" | "sponsorships";

export function ParticipationsTabs({ tab }: { tab: Tab }) {
  const t = useTranslations("learning");
  const tabs: Array<{ key: Tab; label: string; href: string }> = [
    { key: "learning", label: t("tabLearning"), href: "/participations" },
    {
      key: "enrollments",
      label: t("tabEnrollments"),
      href: "/participations?tab=enrollments",
    },
    {
      key: "sponsorships",
      label: t("tabSponsorships"),
      href: "/participations?tab=sponsorships",
    },
  ];

  return (
    <nav
      aria-label={t("navAria")}
      className="flex gap-1 border-b border-line"
      data-testid="participations-tabs"
    >
      {tabs.map((tabItem) => (
        <Link
          key={tabItem.key}
          href={tabItem.href}
          data-testid={`tab-${tabItem.key}`}
          aria-current={tabItem.key === tab ? "page" : undefined}
          className={
            "-mb-px border-b-2 px-4 py-2 text-sm " +
            (tabItem.key === tab
              ? "border-accent font-medium text-ink"
              : "border-transparent text-ink-3 hover:text-ink")
          }
        >
          {tabItem.label}
        </Link>
      ))}
    </nav>
  );
}

/** 学习任务指令文本(Rsk3 降级:复制后粘贴到 OpenClacky 会话)。
 * 组件内传 useTranslations("learning") 的 t;无 provider 的纯函数直调(测试)用
 * zh-CN 源文案的降级 translator,与硬编码原文一致。 */
type LearningTranslate = ReturnType<typeof useTranslations<"learning">>;

const fallbackLearningT = createTranslator({
  locale: "zh-CN",
  messages: zhCN,
  namespace: "learning",
}) as LearningTranslate;

export function learningSessionPrompt(
  detail: CourseLearningDetail,
  issue: LearningIssue,
  t: LearningTranslate = fallbackLearningT,
): string {
  return [
    t("agentPrompt1", { title: detail.title, key: issue.key, issue: issue.title }),
    t("agentGoal", { goal: issue.story.goal ?? t("agentGoalFallback") }),
    t("agentPrompt2"),
  ].join("\n");
}

export default function LearningTab({ runs }: { runs: MyLearningRun[] }) {
  const t = useTranslations("learning");
  const tRoot = useTranslations();
  // 按课程分组(courseId 为空的事件型 run 归「其他学习」组);组序 = runs 顺序
  const groups: Array<{ courseId: string | null; runs: MyLearningRun[] }> = [];
  const groupIndex: Record<string, number> = {};
  for (const run of runs) {
    const key = run.courseId ?? "_none";
    const idx = groupIndex[key];
    if (idx === undefined) {
      groupIndex[key] = groups.length;
      groups.push({ courseId: run.courseId, runs: [run] });
    } else {
      groups[idx].runs.push(run);
    }
  }

  const [drawerCourseId, setDrawerCourseId] = useState<string | null>(null);

  if (runs.length === 0) {
    return (
      <p className="mt-5 text-sm text-ink-3" data-testid="learning-empty">
        {t("empty")}
      </p>
    );
  }

  return (
    <div className="mt-5 grid gap-5" data-testid="learning-groups">
      {groups.map((group) => {
        const primary = group.runs[0];
        const title = primary.targetTitle ?? t("unnamedCourse");

        return (
          <section key={group.courseId ?? "_none"} data-testid="learning-group">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h3 className="text-sm font-medium text-ink-2">{title}</h3>
              {primary.status ? (
                <span className="rounded-full border border-line-strong px-2.5 py-1 text-xs text-ink-2">
                  {tRoot(LEARNING_RUN_STATUS_LABEL[primary.status]) ?? t("processing")}
                </span>
              ) : null}
            </div>

            <div className="mt-2 overflow-hidden rounded-large border border-line">
              {group.runs.map((run) => (
                <div
                  key={run.runId}
                  className="border-b border-line last:border-b-0"
                >
                  <LearningRunRow run={run} onOpenDrawer={setDrawerCourseId} />
                </div>
              ))}
            </div>
          </section>
        );
      })}

      {drawerCourseId ? (
        <IssueDrawer
          courseId={drawerCourseId}
          onClose={() => setDrawerCourseId(null)}
        />
      ) : null}
    </div>
  );
}

function LearningRunRow({
  run,
  onOpenDrawer,
}: {
  run: MyLearningRun;
  onOpenDrawer: (courseId: string) => void;
}) {
  const t = useTranslations("learning");
  // 行级进度 = run 的 doneIssues/totalIssues(投影单源);点行开抽屉看逐条
  const status: IssueStatus =
    run.totalIssues > 0 && run.doneIssues === run.totalIssues
      ? "done"
      : run.doneIssues > 0
        ? "in_progress"
        : "todo";

  return (
    <button
      type="button"
      data-testid="learning-run-row"
      onClick={() => run.courseId && onOpenDrawer(run.courseId)}
      className="flex w-full items-start gap-3 px-4 py-3 text-left hover:bg-soft-2"
    >
      <span className="pt-1">
        <IssueStatusIcon status={status} />
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex flex-wrap items-center gap-2 text-sm font-medium text-ink">
          {run.currentIssueKey ? (
            <span className="font-mono text-[12px] text-ink-3">
              {run.currentIssueKey}
            </span>
          ) : null}
          {run.currentIssueTitle ?? t("learningInProgress")}
        </span>
        {run.totalIssues > 0 ? (
          <span className="mt-0.5 block text-[13px] text-ink-3">
            {t("progressLabel", { done: run.doneIssues, total: run.totalIssues })}
          </span>
        ) : null}
      </span>
    </button>
  );
}

/** 右侧抽屉:课程全部 issue(story 全文 + checklist 逐条 evidence)+ CTA */
function IssueDrawer({
  courseId,
  onClose,
}: {
  courseId: string;
  onClose: () => void;
}) {
  const { data, loading, error } = useQuery(COURSE_LEARNING_DETAIL, {
    variables: { courseId },
  });
  const detail = data?.courseLearningDetail ?? null;

  const t = useTranslations("learning");

  const [openIssueId, setOpenIssueId] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  async function copyPrompt(issue: LearningIssue) {
    if (!detail) return;
    const text = learningSessionPrompt(detail, issue, t);
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // 剪贴板不可用(权限/非安全上下文)——降级为 window.prompt 展示文本
      window.prompt(t("copyPrompt"), text);
    }
  }

  return (
    <div
      className="fixed inset-0 z-40 flex justify-end bg-black/30"
      data-testid="issue-drawer-backdrop"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <aside
        role="dialog"
        aria-label={t("dialogAria")}
        data-testid="issue-drawer"
        className="h-full w-full max-w-xl overflow-y-auto bg-view p-6 shadow-2xl"
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-lg font-semibold text-ink">
              {loading ? t("loading") : (detail?.title ?? t("detailTitle"))}
            </h3>
            {detail ? (
              <p className="mt-1 text-[13px] text-ink-3">
                {detail.progress.doneIssues}/{detail.progress.totalIssues}{" "}
                {t("doneLabel")}
                {detail.progress.currentIssueKey
                  ? t("currentLabel", { key: detail.progress.currentIssueKey })
                  : ""}
              </p>
            ) : null}
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-large border border-line px-3 py-1.5 text-sm text-ink-2 hover:bg-soft-2"
          >
            {t("close")}
          </button>
        </div>

        {error ? (
          <p className="mt-6 text-sm text-ink-3" role="alert">
            {t("loadError")}
          </p>
        ) : null}

        {detail ? (
          <div className="mt-5 grid gap-3" data-testid="drawer-issues">
            {detail.issues.map((issue) => {
              const doneCount = issue.story.checklist.filter(
                (c) => c.done,
              ).length;
              const total = issue.story.checklist.length;
              const expanded = openIssueId === issue.id;

              return (
                <div
                  key={issue.id}
                  className="rounded-large border border-line bg-card"
                >
                  <button
                    type="button"
                    data-testid={`drawer-issue-${issue.id}`}
                    aria-expanded={expanded}
                    onClick={() => setOpenIssueId(expanded ? null : issue.id)}
                    className="flex w-full items-start gap-3 p-4 text-left"
                  >
                    <span className="pt-1">
                      <IssueStatusIcon status={issue.status} />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="flex flex-wrap items-center gap-2 text-sm font-medium text-ink">
                        <span className="font-mono text-[12px] text-ink-3">
                          {issue.key}
                        </span>
                        {issue.title}
                        <IssueKindChip kind={issue.kind} />
                      </span>
                      <span className="mt-0.5 block text-[13px] text-ink-3">
                        {t("doneCountLabel", { done: doneCount, total })}
                      </span>
                    </span>
                  </button>

                  {expanded ? (
                    <div
                      className="border-t border-line p-4"
                      data-testid={`drawer-story-${issue.id}`}
                    >
                      {issue.story.goal ? (
                        <p className="text-sm text-ink-2">
                          <strong>{t("goalLabel")}</strong>
                          {issue.story.goal}
                        </p>
                      ) : null}
                      {issue.story.given.length > 0 ? (
                        <p className="mt-1 text-[13px] text-ink-3">
                          {t("givenLabel", {
                            given: issue.story.given.join(" / "),
                          })}
                        </p>
                      ) : null}
                      {issue.story.materials.length > 0 ? (
                        <ul className="mt-2 grid gap-1 text-[13px] text-ink-3">
                          {issue.story.materials.map((m, i) => (
                            <li key={i}>
                              {t("materialLabel", { title: m.title ?? "" })}
                              {m.ref ? `(${m.ref})` : ""}
                            </li>
                          ))}
                        </ul>
                      ) : null}

                      <ul
                        className="mt-3 grid gap-1.5"
                        data-testid={`drawer-checklist-${issue.id}`}
                      >
                        {issue.story.checklist.map((item) => (
                          <li
                            key={item.id}
                            className="flex items-start gap-2 text-sm"
                            data-testid={`checklist-${issue.id}-${item.id}`}
                            data-done={item.done}
                          >
                            <span
                              className={
                                item.done ? "text-emerald-500" : "text-ink-3"
                              }
                            >
                              {item.done ? "✓" : "○"}
                            </span>
                            <span className="min-w-0 flex-1">
                              <span
                                className={
                                  item.done ? "text-ink-2" : "text-ink"
                                }
                              >
                                {item.text}
                              </span>
                              {item.done && item.evidence ? (
                                <span className="mt-0.5 block text-[12px] text-ink-3">
                                  {t("evidenceLabel", { evidence: item.evidence })}
                                </span>
                              ) : null}
                            </span>
                          </li>
                        ))}
                      </ul>

                      <div className="mt-4 border-t border-line pt-3">
                        <button
                          type="button"
                          data-testid={`cta-learn-${issue.id}`}
                          onClick={() => void copyPrompt(issue)}
                          className="join-button join-button--primary"
                        >
                          {copied ? t("copiedInstruction") : t("tutorThisSection")}
                        </button>
                        <p className="mt-2 text-[12px] text-ink-3">
                          {t("copyHint1")}
                          {t("copyHint2")}
                          <Link
                            href="/settings/integrations"
                            className="text-accent hover:underline"
                          >
                            {t("integrationSettings")}
                          </Link>
                          。
                        </p>
                      </div>
                    </div>
                  ) : null}
                </div>
              );
            })}
          </div>
        ) : null}
      </aside>
    </div>
  );
}
