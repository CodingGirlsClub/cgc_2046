"use client";

import { useParams } from "next/navigation";
import WorkspaceShell from "@/components/workspace-shell";
import { useTranslations } from "next-intl";
import CourseContentViewer from "@/components/learning/course-content-viewer";
import CourseDraftPanel from "@/components/learning/course-draft-panel";
import CourseGovernancePanel from "@/components/learning/course-governance-panel";

export default function CurriculumPreviewPage() {
  const params = useParams<{ slug: string; id: string }>();
  const t = useTranslations("courseReader");
  const courseId = params?.id ?? "";
  return (
    <WorkspaceShell slug={params?.slug ?? ""}>
      <main className="learning-course-page">
        <p className="learning-course-page__back">{t("overview")} <span>›</span> {t("outline")}</p>
        <CourseDraftPanel courseId={courseId} />
        <CourseGovernancePanel courseId={courseId} />
        <CourseContentViewer courseId={courseId} />
      </main>
    </WorkspaceShell>
  );
}
