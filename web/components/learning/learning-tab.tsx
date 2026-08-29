"use client";

/**
 * 我的学习 tab（U8/R11→S8，ADR-0011）：按课程分组 + objective 掌握地图
 * （四态图标/锁定与缺失先修/尝试次数）+ 右侧抽屉（objective 全列表 +
 * next_action 当前任务 + OpenClacky CTA）。
 *
 * 抽屉数据 = courseLearningDetail（Runs.learning_state 薄壳，恒本人视角）；
 * 打开时懒加载。CTA 走 Rsk3 降级路径：复制 objective 口径学习任务指令文本，
 * 引导粘贴到 OpenClacky 会话。
 */

import { Link } from "@/i18n/navigation";
import { useEffect, useState } from "react";
import { createTranslator, useTranslations } from "next-intl";
import zhCN from "@/messages/zh-CN.json";
import { useQuery } from "@apollo/client/react";
import {
  COURSE_LEARNING_DETAIL,
  type CourseLearningDetail,
  type LearningObjectiveState,
  type MyLearningRun,
} from "@/lib/graphql/participations";
import { LEARNING_RUN_STATUS_LABEL } from "@/lib/graphql/participations";
import {
  MasteryIcon,
  type ObjectiveMastery,
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

/** 学习任务指令文本（Rsk3 降级：复制后粘贴到 OpenClacky 会话；S8 objective 口径）。
 * 组件内传 useTranslations("learning") 的 t；无 provider 的纯函数直调(测试)用
 * zh-CN 源文案的降级 translator。 */
type LearningTranslate = ReturnType<typeof useTranslations<"learning">>;

const fallbackLearningT = createTranslator({
  locale: "zh-CN",
  messages: zhCN,
  namespace: "learning",
}) as LearningTranslate;

export function learningSessionPrompt(
  detail: CourseLearningDetail,
  objective: LearningObjectiveState,
  t: LearningTranslate = fallbackLearningT,
): string {
  return [
    t("agentPrompt1", { title: detail.title, issue: objective.title }),
    t("agentObjectiveId", { id: objective.id }),
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
        <ObjectiveDrawer
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
  // 行级进度 = run 的 objective 掌握进度(投影单源);点行开抽屉看逐条
  const mastery: ObjectiveMastery = run.progress.complete
    ? "mastered"
    : run.progress.masteredRequired > 0
      ? "developing"
      : "unassessed";

  return (
    <button
      type="button"
      data-testid="learning-run-row"
      onClick={() => run.courseId && onOpenDrawer(run.courseId)}
      className="flex w-full items-start gap-3 px-4 py-3 text-left hover:bg-soft-2"
    >
      <span className="pt-1">
        <MasteryIcon mastery={mastery} />
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex flex-wrap items-center gap-2 text-sm font-medium text-ink">
          {run.nextAction ? (
            run.nextAction.reason
          ) : (
            <span>{t("learningComplete")}</span>
          )}
          {run.staleRevision ? (
            <span className="rounded-full border border-orange-400 px-2 py-0.5 text-[11px] text-orange-500">
              {t("staleRevision")}
            </span>
          ) : null}
        </span>
        {run.progress.totalRequired > 0 ? (
          <span className="mt-0.5 block text-[13px] text-ink-3">
            {t("progressLabelV2", {
              done: run.progress.masteredRequired,
              total: run.progress.totalRequired,
            })}
          </span>
        ) : null}
      </span>
    </button>
  );
}

/** 右侧抽屉：课程 objective 掌握地图 + next_action 当前任务 + CTA */
function ObjectiveDrawer({
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

  const [copied, setCopied] = useState(false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  async function copyPrompt(objective: LearningObjectiveState) {
    if (!detail) return;
    const text = learningSessionPrompt(detail, objective, t);
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
        data-testid="objective-drawer"
        className="h-full w-full max-w-xl overflow-y-auto bg-view p-6 shadow-2xl"
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-lg font-semibold text-ink">
              {loading ? t("loading") : (detail?.title ?? t("detailTitle"))}
            </h3>
            {detail ? (
              <p className="mt-1 text-[13px] text-ink-3">
                {detail.progress.masteredRequired}/{detail.progress.totalRequired}{" "}
                {t("masteredLabel")}
                {detail.progress.complete ? ` · ${t("completeLabel")}` : ""}
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
          detail.staleRevision ? (
            <p
              className="mt-4 rounded-large border border-orange-400 bg-orange-50 p-3 text-[13px] text-orange-600"
              data-testid="drawer-stale"
            >
              {t("staleRevisionHint")}
            </p>
          ) : null
        ) : null}

        {detail?.nextAction ? (
          <div
            className="mt-4 rounded-large border border-line-strong bg-card p-4"
            data-testid="drawer-next-action"
          >
            <span className="rounded-full border border-accent px-2 py-0.5 text-[11px] text-accent">
              {t("nextActionLabel")}
            </span>
            <p className="mt-2 text-sm text-ink-2">{detail.nextAction.reason}</p>
          </div>
        ) : null}

        {detail ? (
          <div className="mt-5 grid gap-3" data-testid="drawer-objectives">
            {detail.objectives.map((objective) => (
              <div
                key={objective.id}
                className="rounded-large border border-line bg-card"
                data-testid={`drawer-objective-${objective.id}`}
              >
                <div className="flex items-start gap-3 p-4">
                  <span className="pt-0.5">
                    <MasteryIcon mastery={objective.mastery} />
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2 text-sm font-medium text-ink">
                      {objective.title}
                      {objective.required ? null : (
                        <span className="rounded-full border border-violet-400 px-2 py-0.5 text-[11px] text-violet-500">
                          {t("electiveLabel")}
                        </span>
                      )}
                    </div>
                    <div className="mt-0.5 flex flex-wrap gap-3 text-[13px] text-ink-3">
                      {objective.attemptCount > 0 ? (
                        <span>
                          {t("attemptCountLabel", { count: objective.attemptCount })}
                        </span>
                      ) : null}
                      {objective.locked ? (
                        <span
                          className="text-orange-500"
                          data-testid={`objective-locked-${objective.id}`}
                        >
                          🔒{" "}
                          {t("lockedLabel", {
                            titles: objective.missingPrereqIds
                              .map((m) => m.title ?? m.id)
                              .join("、"),
                          })}
                        </span>
                      ) : null}
                    </div>
                  </div>
                  {!objective.locked ? (
                    <button
                      type="button"
                      data-testid={`cta-learn-${objective.id}`}
                      onClick={() => void copyPrompt(objective)}
                      className="join-button join-button--primary shrink-0"
                    >
                      {copied ? t("copiedInstruction") : t("learnThisObjective")}
                    </button>
                  ) : null}
                </div>
              </div>
            ))}
          </div>
        ) : null}

        <p className="mt-4 text-[12px] text-ink-3">
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
      </aside>
    </div>
  );
}
