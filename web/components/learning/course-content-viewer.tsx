"use client";

import { useEffect, useRef, useState } from "react";
import { useQuery } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import {
  COURSE_CONTENT,
  parseCourseContent,
  type CourseContentDocument,
  type CourseContentIssue,
} from "@/lib/graphql/course-content";
import { MaterialRenderer } from "@/components/learning/material-renderer";
import { COURSE_LEARNING_DETAIL, type LearningObjectiveState } from "@/lib/graphql/participations";

/** 章节分组单源：viewer（大纲 + 内容列）与 draft 预览共用，避免双份推导漂移 */
function groupCourseIssues(content: CourseContentDocument, chapterFallback: string) {
  const chapters = content.chapters || [];
  const issues = content.issues || [];
  const chapterTitle = new Map(
    chapters.map((chapter) => [chapter.id, chapter.title || chapter.id || chapterFallback]),
  );
  const grouped = new Map<string, CourseContentIssue[]>();
  for (const issue of issues) {
    const key = issue.chapter_id || "_ungrouped";
    grouped.set(key, [...(grouped.get(key) || []), issue]);
  }
  return { chapters, issues, chapterTitle, grouped };
}

/** 单元卡片 key：与内容区锚点 #course-issue-* 的取值保持一致 */
function issueKeyOf(issue: CourseContentIssue, issueIndex: number) {
  return String(issue.id || issueIndex);
}

/** 总览态：按章节分组的单元任务卡入口，卡片数据全部由 content 推导（kind/目标数/材料数/goal） */
function CourseOverviewCards({
  grouped,
  chapterTitle,
  onOpenIssue,
}: {
  grouped: Map<string, CourseContentIssue[]>;
  chapterTitle: Map<string | undefined, string>;
  onOpenIssue: (chapterId: string, issueKey: string) => void;
}) {
  const t = useTranslations("courseReader");
  return (
    <div className="learning-reader__overview">
      {[...grouped.entries()].map(([chapterId, rows], index) => (
        <section key={chapterId} className="learning-reader__overview-group">
          <div className="learning-reader__chapter-kicker">{t("chapter")} {String(index + 1).padStart(2, "0")}</div>
          <h2>{chapterId === "_ungrouped" ? t("ungrouped") : chapterTitle.get(chapterId)}</h2>
          <div className="learning-reader__overview-grid">
            {rows.map((issue, issueIndex) => {
              const kindText = issue.kind === "thoughtwork" ? t("kind.thoughtwork") : issue.kind === "handwork" ? t("kind.handwork") : null;
              const objectiveCount = (issue.objectives || []).length;
              const materialCount =
                (issue.story?.materials || []).length +
                (issue.objectives || []).flatMap((objective) => objective.materials || []).length;
              const meta = [
                kindText,
                objectiveCount ? `${objectiveCount} ${t("objectives")}` : null,
                materialCount ? `${materialCount} ${t("materials")}` : null,
              ]
                .filter(Boolean)
                .join(" · ");
              const issueKey = issueKeyOf(issue, issueIndex);
              return (
                <button key={issueKey} type="button" className="learning-reader__issue-card" onClick={() => onOpenIssue(chapterId, issueKey)}>
                  {meta ? <div className="learning-reader__issue-card-meta">{meta}</div> : null}
                  <h3>{issue.title || issue.id}</h3>
                  {issue.story?.goal ? <p className="learning-reader__issue-card-goal">{issue.story.goal}</p> : null}
                </button>
              );
            })}
          </div>
        </section>
      ))}
    </div>
  );
}

/** 单个学习单元（issue）内容块：章节全量视图与单单元视图共用 */
function CourseIssueBlock({
  issue,
  issueIndex,
  objectiveStates,
  autoPlay,
}: {
  issue: CourseContentIssue;
  issueIndex: number;
  objectiveStates?: Map<string, LearningObjectiveState>;
  /** 单元视图：视频材料挂载即自动播放（draft 全量预览保持点击播放） */
  autoPlay?: boolean;
}) {
  const t = useTranslations("courseReader");
  // 单元 meta 行：kind 走 courseReader.kind.* 翻译；未知/缺失 kind 不注入原始串
  const kindText = issue.kind === "thoughtwork" ? t("kind.thoughtwork") : issue.kind === "handwork" ? t("kind.handwork") : null;
  return (
    <div id={`course-issue-${issueKeyOf(issue, issueIndex)}`} className="learning-reader__issue" data-testid="course-content-issue">
      <div className="learning-reader__issue-meta">{kindText ? t("unitMeta", { kind: kindText }) : t("units")}</div>
      <h3>{issue.title || issue.id}</h3>
      {issue.story?.goal ? <p className="learning-reader__goal">{issue.story.goal}</p> : null}
      {(issue.story?.materials || []).map((material, materialIndex) => (
        <MaterialRenderer key={materialIndex} material={material} autoPlay={autoPlay} />
      ))}
      {(issue.objectives || []).map((objective, objectiveIndex) => (
        <div id={objective.id ? `objective-${objective.id}` : undefined} key={objective.id || objectiveIndex} className="learning-reader__objective" data-testid="course-content-objective">
          {(() => {
            const state = objective.id ? objectiveStates?.get(objective.id) : undefined;
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
            <MaterialRenderer key={materialIndex} material={material} autoPlay={autoPlay} />
          ))}
        </div>
      ))}
    </div>
  );
}

/**
 * 课程内容列（章节 → 学习单元 → 目标/材料）渲染主体。
 * 已发布 viewer 与教研 draft 预览共用；objectiveStates 仅学员学习态覆盖时传入。
 */
export function CourseContentSections({
  content,
  objectiveStates,
}: {
  content: CourseContentDocument;
  objectiveStates?: Map<string, LearningObjectiveState>;
}) {
  const t = useTranslations("courseReader");
  const { chapterTitle, grouped } = groupCourseIssues(content, t("chapter"));

  return (
    <div className="learning-reader__content">
      {[...grouped.entries()].map(([chapterId, rows], index) => (
        <section key={chapterId} className="learning-reader__chapter" aria-labelledby={`course-chapter-${chapterId}`}>
          <div className="learning-reader__chapter-kicker">{t("chapter")} {String(index + 1).padStart(2, "0")}</div>
          <h2 id={`course-chapter-${chapterId}`}>{chapterId === "_ungrouped" ? t("ungrouped") : chapterTitle.get(chapterId)}</h2>
          {rows.map((issue, issueIndex) => (
            <CourseIssueBlock key={issueKeyOf(issue, issueIndex)} issue={issue} issueIndex={issueIndex} objectiveStates={objectiveStates} />
          ))}
        </section>
      ))}
    </div>
  );
}

export default function CourseContentViewer({ courseId }: { courseId: string }) {
  const t = useTranslations("courseReader");
  const { data, loading, error } = useQuery(COURSE_CONTENT, { variables: { courseId } });
  const { data: learningData } = useQuery(COURSE_LEARNING_DETAIL, { variables: { courseId } });
  /** 单元导航状态：null = 总览态；否则主区只渲染 issueKey 对应的单元内容 */
  const [active, setActive] = useState<{ chapterId: string; issueKey: string } | null>(null);
  const [outlineOpen, setOutlineOpen] = useState(false);
  // 导航动作后回顶；跳过初挂载，避免覆盖浏览器刷新恢复的滚动位置
  const mounted = useRef(false);
  useEffect(() => {
    if (!mounted.current) {
      mounted.current = true;
      return;
    }
    window.scrollTo({ top: 0 });
  }, [active]);
  if (loading) return <p data-testid="course-content-loading">{t("loading")}</p>;
  if (error) return <p role="alert">{t("loadFailed")}</p>;
  const detail = data?.courseContent;
  if (!detail)
    return (
      <div data-testid="course-content-empty">
        <p className="font-medium text-ink">{t("empty")}</p>
        <p className="mt-1 text-sm text-ink-3">{t("emptyHint")}</p>
        <Link href="/learning" className="mt-3 inline-block text-[13px] text-accent hover:underline">
          {t("openLearning")} ↗
        </Link>
      </div>
    );
  const content = parseCourseContent(detail.content);
  const { issues, chapterTitle, grouped } = groupCourseIssues(content, t("chapter"));
  const objectives = issues.flatMap((issue) => issue.objectives || []);
  const materials = issues.flatMap((issue) => [
    ...(issue.story?.materials || []),
    ...(issue.objectives || []).flatMap((objective) => objective.materials || []),
  ]);
  const objectiveStates = new Map<string, LearningObjectiveState>(
    (learningData?.courseLearningDetail?.objectives || []).map((objective) => [objective.id, objective]),
  );
  const masterCount = objectives.filter((objective) => objectiveStates.get(objective.id ?? "")?.mastery === "mastered").length;
  const activeRows = active ? grouped.get(active.chapterId) : undefined;
  const activeIssueIndex = activeRows?.findIndex((issue, index) => issueKeyOf(issue, index) === active?.issueKey) ?? -1;
  const activeIssue = activeIssueIndex >= 0 ? activeRows?.[activeIssueIndex] : undefined;
  const activeChapterIndex = active ? [...grouped.keys()].indexOf(active.chapterId) : -1;
  // 手机两页模型：目录页（总览）↔ 内容页（单元）；展平序供「上一单元/下一单元」跨章翻页
  const flatUnits = [...grouped.entries()].flatMap(([chapterId, rows]) =>
    rows.map((issue, issueIndex) => ({ chapterId, issueKey: issueKeyOf(issue, issueIndex) })));
  const flatPos = active ? flatUnits.findIndex((unit) => unit.chapterId === active.chapterId && unit.issueKey === active.issueKey) : -1;
  const prevUnit = flatPos > 0 ? flatUnits[flatPos - 1] : undefined;
  const nextUnit = flatPos >= 0 && flatPos < flatUnits.length - 1 ? flatUnits[flatPos + 1] : undefined;
  // 大纲树：桌面侧边栏与手机目录浮层共用；浮层内点选后收起（outlineOpen 在桌面恒 false，无副作用）
  const outlineNav = (
    <>
      <div className="learning-reader__outline-group">
        <button
          type="button"
          className={`learning-reader__outline-home${active ? "" : " is-active"}`}
          onClick={() => {
            setActive(null);
            setOutlineOpen(false);
          }}
        >
          {t("overview")}
        </button>
      </div>
      {[...grouped.entries()].map(([chapterId, rows], index) => (
        <div key={chapterId} className="learning-reader__outline-group">
          <div className={`learning-reader__outline-chapter${active?.chapterId === chapterId ? " is-active" : ""}`}>
            <span>{String(index + 1).padStart(2, "0")}</span>
            {chapterId === "_ungrouped" ? t("ungrouped") : chapterTitle.get(chapterId)}
          </div>
          {rows.map((issue, issueIndex) => {
            const issueKey = issueKeyOf(issue, issueIndex);
            return (
              <a
                key={issueKey}
                href={`#course-issue-${issueKey}`}
                className={active?.issueKey === issueKey ? "is-active" : undefined}
                onClick={(event) => {
                  event.preventDefault();
                  setActive({ chapterId, issueKey });
                  setOutlineOpen(false);
                }}
              >
                {issue.title || issue.id}
              </a>
            );
          })}
        </div>
      ))}
    </>
  );

  return (
    <article className={`learning-reader${active ? " learning-reader--unit" : " learning-reader--overview"}`} data-testid="course-content-viewer">
      <header className="learning-reader__hero">
        <div className="learning-reader__hero-row">
          <div>
            <h1>{detail.title}</h1>
            <p>{detail.description || t("intro")}</p>
          </div>
          <span className="learning-reader__version">{t("version")} {detail.revisionNumber ?? "—"}</span>
        </div>
        <div className="learning-reader__stats" aria-label={t("overview")}>
          <span><strong>{(content.chapters || []).length}</strong> {t("chapter")}</span>
          <span><strong>{issues.length}</strong> {t("units")}</span>
          <span><strong>{objectives.length}</strong> {t("objectives")}</span>
          <span><strong>{materials.length}</strong> {t("materials")}</span>
          <span><strong>{masterCount}/{objectives.length}</strong> {t("mastered")}</span>
        </div>
      </header>

      <div className="learning-reader__layout">
        <aside className="learning-reader__outline" aria-label={t("outline")}>
          <div className="learning-reader__outline-label">{t("outline")}</div>
          {outlineNav}
        </aside>

        {active && activeIssue ? (
          <div className="learning-reader__content">
            <div className="learning-reader__unit-nav">
              <button type="button" className="learning-reader__unit-nav-home" onClick={() => setOutlineOpen(true)}>‹ {t("outline")}</button>
              <span className="learning-reader__unit-nav-spacer" />
              {prevUnit ? (
                <button type="button" onClick={() => setActive({ chapterId: prevUnit.chapterId, issueKey: prevUnit.issueKey })}>‹ {t("prevUnit")}</button>
              ) : null}
              {nextUnit ? (
                <button type="button" onClick={() => setActive({ chapterId: nextUnit.chapterId, issueKey: nextUnit.issueKey })}>{t("nextUnit")} ›</button>
              ) : null}
            </div>
            <div className="learning-reader__chapter-kicker">
              {t("chapter")} {String(activeChapterIndex + 1).padStart(2, "0")} · {active.chapterId === "_ungrouped" ? t("ungrouped") : chapterTitle.get(active.chapterId)}
            </div>
            <CourseIssueBlock issue={activeIssue} issueIndex={activeIssueIndex} objectiveStates={objectiveStates} autoPlay />
          </div>
        ) : (
          <CourseOverviewCards grouped={grouped} chapterTitle={chapterTitle} onOpenIssue={(chapterId, issueKey) => setActive({ chapterId, issueKey })} />
        )}

        <aside className="learning-reader__progress" aria-label={t("progress")}>
          <div className="learning-reader__progress-label">{t("currentCourse")}</div>
          <div className="learning-reader__progress-number">{masterCount}<span>/{objectives.length}</span></div>
          <p>{t("masteredGoals")}</p>
          <div className="learning-reader__progress-track"><span style={{ width: `${objectives.length ? Math.round((masterCount / objectives.length) * 100) : 0}%` }} /></div>
          <div className="learning-reader__progress-note">{t("progressNote")}</div>
          <Link className="learning-reader__agent-link" href="/learning">{t("openLearning")} <span>↗</span></Link>
        </aside>
      </div>
      {outlineOpen ? (
        <div className="learning-reader__outline-overlay" role="dialog" aria-modal="true" aria-label={t("outline")}>
          <div className="learning-reader__outline-overlay-head">
            <span className="learning-reader__outline-label">{t("outline")}</span>
            <button type="button" onClick={() => setOutlineOpen(false)}>{t("closeOutline")}</button>
          </div>
          <div className="learning-reader__outline-overlay-progress">
            <span className="learning-reader__progress-number">{masterCount}<span>/{objectives.length}</span></span>
            <div className="learning-reader__progress-track"><span style={{ width: `${objectives.length ? Math.round((masterCount / objectives.length) * 100) : 0}%` }} /></div>
          </div>
          <nav className="learning-reader__outline learning-reader__outline--overlay" aria-label={t("outline")}>
            {outlineNav}
          </nav>
        </div>
      ) : null}
    </article>
  );
}
