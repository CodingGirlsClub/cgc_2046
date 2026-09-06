"use client";

import { useQuery } from "@apollo/client/react";
import { Link } from "@/i18n/navigation";
import { COURSE_CONTENT, parseCourseContent } from "@/lib/graphql/course-content";
import { MaterialRenderer } from "@/components/learning/material-renderer";
import { COURSE_LEARNING_DETAIL, type LearningObjectiveState } from "@/lib/graphql/participations";



export default function CourseContentViewer({ courseId }: { courseId: string }) {
  const { data, loading, error } = useQuery(COURSE_CONTENT, { variables: { courseId } });
  const { data: learningData } = useQuery(COURSE_LEARNING_DETAIL, { variables: { courseId } });
  if (loading) return <p data-testid="course-content-loading">加载课程内容…</p>;
  if (error) return <p role="alert">课程内容加载失败</p>;
  const detail = data?.courseContent;
  if (!detail) return <p>暂无可读课程内容</p>;
  const content = parseCourseContent(detail.content);
  const chapters = content.chapters || [];
  const issues = content.issues || [];
  const chapterTitle = new Map(chapters.map((chapter) => [chapter.id, chapter.title || chapter.id || "章节"]));
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
        <div className="learning-reader__eyebrow">我的学习 / 课程阅读</div>
        <div className="learning-reader__hero-row">
          <div>
            <h1>{detail.title}</h1>
            <p>按章节阅读课程内容，选择一个目标开始学习。</p>
          </div>
          <span className="learning-reader__version">版本 {detail.revisionNumber ?? "—"}</span>
        </div>
        <div className="learning-reader__stats" aria-label="课程概览">
          <span><strong>{chapters.length}</strong> 章节</span>
          <span><strong>{issues.length}</strong> 学习单元</span>
          <span><strong>{objectives.length}</strong> 学习目标</span>
          <span><strong>{materials.length}</strong> 份材料</span>
        </div>
      </header>

      <div className="learning-reader__layout">
        <aside className="learning-reader__outline" aria-label="课程目录">
          <div className="learning-reader__outline-label">课程目录</div>
          {[...grouped.entries()].map(([chapterId, rows], index) => (
            <div key={chapterId} className="learning-reader__outline-group">
              <div className="learning-reader__outline-chapter">
                <span>{String(index + 1).padStart(2, "0")}</span>
                {chapterId === "_ungrouped" ? "未分组" : chapterTitle.get(chapterId)}
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
              <div className="learning-reader__chapter-kicker">章节 {String(index + 1).padStart(2, "0")}</div>
              <h2 id={`course-chapter-${chapterId}`}>{chapterId === "_ungrouped" ? "未分组" : chapterTitle.get(chapterId)}</h2>
              {rows.map((issue, issueIndex) => (
                <div id={`course-issue-${issue.id || issueIndex}`} key={issue.id || issueIndex} className="learning-reader__issue" data-testid="course-content-issue">
                  <div className="learning-reader__issue-meta">学习单元 · {issue.kind || "课程内容"}</div>
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
                              {state ? <span className={`learning-reader__mastery learning-reader__mastery--${state.mastery}`}>{state.mastery === "mastered" ? "已掌握" : state.mastery === "developing" ? "学习中" : state.mastery === "needs_review" ? "待复习" : "未开始"}</span> : null}
                            </div>
                            {objective.assessment ? <p className="learning-reader__assessment"><strong>验收</strong>{objective.assessment}</p> : null}
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

        <aside className="learning-reader__progress" aria-label="学习进度">
          <div className="learning-reader__progress-label">本课程</div>
          <div className="learning-reader__progress-number">0<span>/{objectives.length}</span></div>
          <p>已掌握目标</p>
          <div className="learning-reader__progress-track"><span /></div>
          <div className="learning-reader__progress-note">完成一个目标后，进度会在这里更新。</div>
          <Link className="learning-reader__agent-link" href="/learning">打开我的学习 <span>↗</span></Link>
        </aside>
      </div>
    </article>
  );
}
