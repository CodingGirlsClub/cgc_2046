"use client";

import { useParams } from "next/navigation";
import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import SitePage from "@/components/site-page";
import CourseContentViewer from "@/components/learning/course-content-viewer";

export default function CourseLearningPage() {
  const params = useParams<{ id: string }>();
  const courseId = params?.id ?? "";
  const t = useTranslations("courseReader");
  return (
    <SitePage>
      <main className="learning-course-page">
        <p className="learning-course-page__back"><Link href="/learning">{t("eyebrow")}</Link><span>›</span>{t("outline")}</p>
        <CourseContentViewer courseId={courseId} />
      </main>
    </SitePage>
  );
}
