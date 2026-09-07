"use client";

import { useQuery } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { COURSE_CONTENT, parseCourseContent } from "@/lib/graphql/course-content";
import { MaterialRenderer } from "@/components/learning/material-renderer";
import { COURSE_LEARNING_DETAIL, type LearningObjectiveState } from "@/lib/graphql/participations";



export default function CourseContentViewer({ courseId }: { courseId: string }) {
  const t = useTranslations("courseReader");
  const { data, loading, error } = useQuery(COURSE_CONTENT, { variables: { courseId } });
  const { data: learningData } = useQuery(COURSE_LEARNING_DETAIL, { variables: { courseId } });
  if (loading) return <p data-testid="course-content-loading">{t("loading")}</p>;
  if (error) return <p role="alert">{t("loadFailed")}</p>;
  const detail = data?.courseContent;
  if (!detail) return <p>{t("empty")}</p>;
  const content = parseCourseContent(detail.content);
  const chapters = content.chapters || [];
  const issues = content.issues || [];
  const kindLabel = (kind?: string) => kind === "thoughtwork" ? t("thoughtwork") : kind === "handwork" ? t("handwork") : kind || t("units");
  const chapterTitle = new Map(chapters.map((chapter) => [chapter.id, chapter.title || chapter.id || t("chapter")]));
  const grouped = new Map<string, typeof issues>();
  for (const issue of issues) {
    const key = issue.chapter_id || "_ungrouped";
    grouped.set(key, [...(grouped.get(key) || []), issue]);
  }
  const objectives = issues.flatMap((issue) => issue.objectives || []);
  const materials = issues.flatMap((issue) => [
    ...(issue.story?.materials || []),
    ...(issue.objectives || []).flatMap((objective) => objective.materials || []),
  ]);
  const objectiveStates = new Map<string, LearningObjectiveState>(
    (learningData?.courseLearningDetail?.objectives || []).map((objective) => [objective.id, objective]),
  );

  return (
    <article className="learning-reader" data-testid="course-content-viewer">
      <header className="learning-reader__hero">
        <div className="learning-reader__eyebrow">{t("eyebrow")}</div>
        <div className="learning-reader__hero-row">
          <div>
            <h1>{detail.title}</h1>
            <p>{t("intro")}</p>
          </div>
          <span className="learning-reader__version">{t("version")} {detail.revisionNumber ?? "—"}</span>
        </div>
        <div className="learning-reader__stats" aria-label={t("overview")}>
          <span><strong>{chapters.length}</strong> {t("chapter")}</span>
          <span><strong>{issues.length}</strong> {t("units")}</span>
          <span><strong>{objectives.length}</strong> {t("objectives")}</span>
          <span><strong>{materials.length}</strong> {t("materials")}</span>
        </div>
      </header>

      <div className="learning-reader__layout">
        <aside className="learning-reader__outline" aria-label={t("outline")}>
          <div className="learning-reader__outline-label">{t("outline")}</div>
          {[...grouped.entries()].map(([chapterId, rows], index) => (
            <div key={chapterId} className="learning-reader__outline-group">
              <div className="learning-reader__outline-chapter">
                <span>{String(index + 1).padStart(2, "0")}</span>
                {chapterId === "_ungrouped" ? t("ungrouped") : chapterTitle.get(chapterId)}
              </div>
              {rows.map((issue, issueIndex) => (
                <a key={issue.id || issueIndex} href={`#course-issue-${issue.id || issueIndex}`}>
                  {issue.title || issue.id}
                </a>
              ))}
            </div>
          ))}
        </aside>

        <div className="learning-reader__content">
          {[...grouped.entries()].map(([chapterId, rows], index) => (
            <section key={chapterId} className="learning-reader__chapter" aria-labelledby={`course-chapter-${chapterId}`}>
              <div className="learning-reader__chapter-kicker">{t("chapter")} {String(index + 1).padStart(2, "0")}</div>
              <h2 id={`course-chapter-${chapterId}`}>{chapterId === "_ungrouped" ? t("ungrouped") : chapterTitle.get(chapterId)}</h2>
              {rows.map((issue, issueIndex) => (
                <div id={`course-issue-${issue.id || issueIndex}`} key={issue.id || issueIndex} className="learning-reader__issue" data-testid="course-content-issue">
                  <div className="learning-reader__issue-meta">{t("unitMeta", { kind: kindLabel(issue.kind) })}</div>
                  <h3>{issue.title || issue.id}</h3>
                  {issue.story?.goal ? <p className="learning-reader__goal">{issue.story.goal}</p> : null}
                  {(issue.story?.materials || []).map((material, materialIndex) => (
                    <MaterialRenderer key={materialIndex} material={material} />
                  ))}
                  {(issue.objectives || []).map((objective, objectiveIndex) => (
                    <div id={objective.id ? `objective-${objective.id}` : undefined} key={objective.id || objectiveIndex} className="learning-reader__objective" data-testid="course-content-objective">
                      {(() => {
                        const state = objective.id ? objectiveStates.get(objective.id) : undefined;
                        return (
                          <>
                            <div className="learning-reader__objective-title">
                              <span className="learning-reader__objective-dot" />
                              <span>{objective.title || objective.id}</span>
                              {state ? <span className={`learning-reader__mastery learning-reader__mastery--${state.mastery}`}>{state.mastery === "mastered" ? t("mastered") : state.mastery === "developing" ? t("learning") : state.mastery === "needs_review" ? t("review") : t("notStarted")}</span> : null}
                            </div>
                            {objective.assessment ? <p className="learning-reader__assessment"><strong>{t("assessment")}</strong>{objective.assessment}</p> : null}
                            {objective.rubric?.length ? (
                              <ul className="learning-reader__rubric">
                                {objective.rubric.map((criterion, criterionIndex) => <li key={criterion.id || criterionIndex}>{criterion.text || criterion.id}</li>)}
                              </ul>
                            ) : null}
                          </>
                        );
                      })()}
                      {objective.activity ? <p>{objective.activity}</p> : null}
                      {(objective.materials || []).map((material, materialIndex) => (
                        <MaterialRenderer key={materialIndex} material={material} />
                      ))}
                    </div>
                  ))}
                </div>
              ))}
            </section>
          ))}
        </div>

        <aside className="learning-reader__progress" aria-label={t("progress")}>
          <div className="learning-reader__progress-label">{t("currentCourse")}</div>
          <div className="learning-reader__progress-number">0<span>/{objectives.length}</span></div>
          <p>{t("masteredGoals")}</p>
          <div className="learning-reader__progress-track"><span /></div>
          <div className="learning-reader__progress-note">{t("progressNote")}</div>
          <Link className="learning-reader__agent-link" href="/learning">{t("openLearning")} <span>↗</span></Link>
        </aside>
      </div>
    </article>
  );
}
