"use client";

import { useState, useSyncExternalStore } from "react";
import { useParams } from "next/navigation";
import { useQuery } from "@apollo/client/react";
import { Link } from "@/i18n/navigation";
import { useLocale, useTranslations } from "next-intl";
import SitePage from "@/components/site-page";
import CourseContentViewer from "@/components/learning/course-content-viewer";
import HostChatPanel from "@/components/learning/host-chat-panel";
import { useAuthed } from "@/lib/auth-provider";
import { COURSE_CONTENT } from "@/lib/graphql/course-content";
import { COURSE_LEARNING_DETAIL } from "@/lib/graphql/participations";

/** KTD11：视口不窄于它才并排显示对话栏（1280px 下阅读区约 600px）；更窄时不挂载，保持原有体验 */
const CHAT_QUERY = "(min-width: 1280px)";

function useChatViewport(): boolean {
  return useSyncExternalStore(
    (callback) => {
      const query = window.matchMedia(CHAT_QUERY);
      query.addEventListener("change", callback);
      return () => query.removeEventListener("change", callback);
    },
    () => window.matchMedia(CHAT_QUERY).matches,
    () => false,
  );
}

export default function CourseLearningPage() {
  const params = useParams<{ id: string }>();
  const courseId = params?.id ?? "";
  const t = useTranslations("courseReader");
  const locale = useLocale();
  const { userId } = useAuthed();
  const wide = useChatViewport();
  const [unitId, setUnitId] = useState<string | null>(null);
  // 与阅读组件同一查询、同一变量：共用 Apollo 缓存，不多发请求
  const { data: content } = useQuery(COURSE_CONTENT, { variables: { courseId } });
  const { data: learning } = useQuery(COURSE_LEARNING_DETAIL, { variables: { courseId } });
  // 只给报了名（有学习详情）的学员显示：对话的上下文要带 workspaceId（KTD8）
  const workspaceId = learning?.courseLearningDetail?.workspaceId;
  const chat = wide && userId && workspaceId ? { userId, workspaceId } : null;
  return (
    <SitePage>
      <main className={`learning-course-page${chat ? " learning-course-page--chat" : ""}`}>
        <p className="learning-course-page__back"><Link href="/learning">{t("home")}</Link><span>›</span>{t("outline")}</p>
        <CourseContentViewer courseId={courseId} compact={chat !== null} onUnitChange={setUnitId} />
        {chat ? (
          // 换账号、换课程即重新挂载：连接与对话从头来过（同一标签页换账号要重新连 Host）
          <HostChatPanel
            key={`${chat.userId}:${courseId}`}
            courseId={courseId}
            userId={chat.userId}
            locale={locale}
            workspaceId={chat.workspaceId}
            courseVersion={content?.courseContent?.revisionNumber ?? null}
            unitId={unitId}
          />
        ) : null}
      </main>
    </SitePage>
  );
}
