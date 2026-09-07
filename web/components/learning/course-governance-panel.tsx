"use client";

import { useQuery } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import { COURSE_LEARNING_ANALYTICS } from "@/lib/graphql/course-content";

export default function CourseGovernancePanel({ courseId }: { courseId: string }) {
  const t = useTranslations("courseGovernance");
  const { data, loading, error } = useQuery(COURSE_LEARNING_ANALYTICS, { variables: { courseId } });
  if (loading) return <section className="learning-governance" data-testid="course-governance-loading">{t("loading")}</section>;
  if (error) return <section className="learning-governance" role="alert">{t("error")}</section>;
  const analytics = data?.courseLearningAnalytics;
  if (!analytics) return <section className="learning-governance" data-testid="course-governance-empty">{t("unavailable")}</section>;
  const { runStats, dropOff } = analytics;
  const rate = runStats.completionRate == null ? "—" : `${Math.round(runStats.completionRate * 100)}%`;
  return (
    <section className="learning-governance" data-testid="course-governance-panel" aria-label={t("aria")}>
      <div className="learning-governance__header"><div><span className="learning-reader__eyebrow">{t("eyebrow")}</span><h2>{t("title")}</h2></div><span className="learning-governance__privacy">{t("privacy")}</span></div>
      <div className="learning-governance__stats">
        <div><strong>{runStats.totalRuns}</strong><span>{t("runs")}</span></div>
        <div><strong>{runStats.activeRuns}</strong><span>{t("active")}</span></div>
        <div><strong>{runStats.completedRuns}</strong><span>{t("completed")}</span></div>
        <div><strong>{rate}</strong><span>{t("rate")}</span></div>
        <div><strong>{dropOff.staleRunCount}</strong><span>{t("stale")}</span></div>
      </div>
      <div className="learning-governance__objectives">
        <h3>{t("objectiveState")}</h3>
        {analytics.objectives.length === 0 ? <p>{t("noObjectives")}</p> : analytics.objectives.map((objective) => (
          <div className="learning-governance__objective" key={objective.objectiveId}>
            <div><strong>{objective.title}</strong><span>{objective.required ? t("required") : t("elective")}</span></div>
            <p>{t("counts", { mastered: objective.mastered, developing: objective.developing, needsReview: objective.needsReview, unassessed: objective.unassessed })}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
