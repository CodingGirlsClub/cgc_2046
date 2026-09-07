"use client";

import { useParams } from "next/navigation";
import WorkspaceShell from "@/components/workspace-shell";
import { useTranslations } from "next-intl";
import CourseContentViewer from "@/components/learning/course-content-viewer";
import CourseGovernancePanel from "@/components/learning/course-governance-panel";

export default function CurriculumPreviewPage() {
  const params = useParams<{ slug: string; id: string }>();
  const t = useTranslations("courseReader");
  return (
    <WorkspaceShell slug={params?.slug ?? ""}>
      <main className="learning-course-page">
        <p className="learning-course-page__back">{t("overview")} <span>›</span> {t("outline")}</p>
        <CourseGovernancePanel courseId={params?.id ?? ""} />
        <CourseContentViewer courseId={params?.id ?? ""} />
      </main>
    </WorkspaceShell>
  );
}
