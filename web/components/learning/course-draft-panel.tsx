"use client";

import { useQuery } from "@apollo/client/react";
import { useLocale, useTranslations } from "next-intl";
import {
  COURSE_DRAFT,
  parseCourseContent,
} from "@/lib/graphql/course-content";
import { CourseContentSections } from "@/components/learning/course-content-viewer";

/**
 * 教研 draft 预览区块（H6）：/w/[slug]/courses/[id]/curriculum 治理投影区上方。
 *
 * 数据语义与后端 courseDraft 一致：无权（非 tutor/owner/admin）或无 draft 时
 * 返回 null，本区块整体不渲染（loading/请求失败同样静默——治理面板在下方
 * 自带错误态，避免双错误噪音）。内容渲染复用 CourseContentSections（与已发布
 * viewer 同一渲染主体，不复制）。
 */

/** prepState 五态（后端 Curriculum.Prep @prep_states）→ messages key；未知枚举回退原串 */
const PREP_STATE_KEY: Record<string, string> = {
  draft: "draft.state.draft",
  authoring: "draft.state.authoring",
  quality_check: "draft.state.qualityCheck",
  review: "draft.state.review",
  published: "draft.state.published",
};

export default function CourseDraftPanel({ courseId }: { courseId: string }) {
  const t = useTranslations("courseGovernance");
  const locale = useLocale();
  const { data, loading, error } = useQuery(COURSE_DRAFT, {
    variables: { courseId },
  });
  if (loading || error) return null;
  const draft = data?.courseDraft ?? null;
  // nil 语义与后端一致：courseDraft=null → 无权/课程不存在；version=null → 有权但尚无草稿，均不渲染
  if (!draft || draft.version == null) return null;

  const content = parseCourseContent(draft.content);
  const stateKey = draft.prepState ? PREP_STATE_KEY[draft.prepState] : undefined;
  const updatedAt = draft.updatedAt
    ? new Date(draft.updatedAt).toLocaleString(locale === "en" ? "en-US" : "zh-CN")
    : "—";

  return (
    <section
      className="learning-governance"
      data-testid="course-draft-panel"
      aria-label={t("draft.aria")}
    >
      <div className="learning-governance__header">
        <div>
          <span className="learning-reader__eyebrow">{t("draft.eyebrow")}</span>
          <h2>{draft.title}</h2>
        </div>
        {draft.prepState ? (
          <span
            className="learning-governance__privacy"
            data-testid="course-draft-state"
          >
            {stateKey ? t(stateKey) : draft.prepState}
          </span>
        ) : null}
      </div>
      <p data-testid="course-draft-meta">
        {t("draft.meta", { version: draft.version, time: updatedAt })}
      </p>
      <CourseContentSections content={content} />
    </section>
  );
}
