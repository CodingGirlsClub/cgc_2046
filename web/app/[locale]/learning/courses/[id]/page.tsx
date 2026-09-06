"use client";

import { useParams } from "next/navigation";
import { Link } from "@/i18n/navigation";
import SitePage from "@/components/site-page";
import CourseContentViewer from "@/components/learning/course-content-viewer";

export default function CourseLearningPage() {
  const params = useParams<{ id: string }>();
  const courseId = params?.id ?? "";
  return (
    <SitePage>
      <main className="learning-course-page">
        <p className="learning-course-page__back"><Link href="/learning">我的学习</Link><span>›</span>课程内容</p>
        <CourseContentViewer courseId={courseId} />
      </main>
    </SitePage>
  );
}
