"use client";

import { useQuery } from "@apollo/client/react";
import { COURSE_LEARNING_ANALYTICS } from "@/lib/graphql/course-content";

export default function CourseGovernancePanel({ courseId }: { courseId: string }) {
  const { data, loading, error } = useQuery(COURSE_LEARNING_ANALYTICS, { variables: { courseId } });
  if (loading) return <section className="learning-governance" data-testid="course-governance-loading">课程治理数据加载中…</section>;
  if (error) return <section className="learning-governance" role="alert">课程治理数据暂时不可用</section>;
  const analytics = data?.courseLearningAnalytics;
  if (!analytics) return <section className="learning-governance" data-testid="course-governance-empty">当前角色无权查看治理统计</section>;
  const { runStats, dropOff } = analytics;
  const rate = runStats.completionRate == null ? "—" : `${Math.round(runStats.completionRate * 100)}%`;
  return (
    <section className="learning-governance" data-testid="course-governance-panel" aria-label="课程治理统计">
      <div className="learning-governance__header"><div><span className="learning-reader__eyebrow">课程治理 / 教学投影</span><h2>发布版本与学习概览</h2></div><span className="learning-governance__privacy">不含学习证据正文</span></div>
      <div className="learning-governance__stats">
        <div><strong>{runStats.totalRuns}</strong><span>学习运行</span></div>
        <div><strong>{runStats.activeRuns}</strong><span>进行中</span></div>
        <div><strong>{runStats.completedRuns}</strong><span>已完成</span></div>
        <div><strong>{rate}</strong><span>完成率</span></div>
        <div><strong>{dropOff.staleRunCount}</strong><span>超过 7 天未活动</span></div>
      </div>
      <div className="learning-governance__objectives">
        <h3>目标教学状态</h3>
        {analytics.objectives.length === 0 ? <p>当前发布版本暂无目标统计。</p> : analytics.objectives.map((objective) => (
          <div className="learning-governance__objective" key={objective.objectiveId}>
            <div><strong>{objective.title}</strong><span>{objective.required ? "必修" : "选修"}</span></div>
            <p>已掌握 {objective.mastered} · 学习中 {objective.developing} · 待复习 {objective.needsReview} · 未评估 {objective.unassessed}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
