import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

export interface CourseContentResponse {
  courseContent: {
    courseId: string;
    title: string;
    revisionNumber: number | null;
    publishedAt: string | null;
    content: string;
  } | null;
}

export const COURSE_CONTENT: TypedDocumentNode<
  CourseContentResponse,
  { courseId: string }
> = gql`
  query CourseContent($courseId: ID!) {
    courseContent(courseId: $courseId) {
      courseId
      title
      revisionNumber
      publishedAt
      content
    }
  }
`;

export interface TypedMaterial {
  kind?: "text" | "markdown" | "web" | "image" | "video";
  title?: string;
  body?: string;
  url?: string;
  provider?: string;
  external_id?: string;
  alt_text?: string;
  caption?: string;
  ref?: string;
}

export interface CourseContentIssue {
  id?: string;
  kind?: string;
  title?: string;
  chapter_id?: string;
  story?: {
    goal?: string;
    materials?: TypedMaterial[];
  };
  objectives?: Array<{
    id?: string;
    title?: string;
    activity?: string;
    assessment?: string;
    materials?: TypedMaterial[];
    rubric?: Array<{ id?: string; text?: string }>;
  }>;
}

export interface CourseContentDocument {
  goals?: string[];
  chapters?: Array<{ id?: string; title?: string }>;
  issues?: CourseContentIssue[];
}

export function parseCourseContent(raw: string | null | undefined): CourseContentDocument {
  if (!raw) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as CourseContentDocument)
      : {};
  } catch {
    return {};
  }
}

export interface CourseLearningAnalytics {
  runStats: { totalRuns: number; activeRuns: number; completedRuns: number; completionRate: number | null };
  objectives: Array<{ objectiveId: string; title: string; required: boolean; mastered: number; developing: number; needsReview: number; unassessed: number; totalAttempts: number; qualifyingPasses: number; lowConfidenceAttempts: number; passRate: number | null; lastActivityAt: string | null }>;
  dropOff: { staleRunCount: number };
  generatedAt: string;
}

export const COURSE_LEARNING_ANALYTICS: TypedDocumentNode<
  { courseLearningAnalytics: CourseLearningAnalytics | null },
  { courseId: string }
> = gql`
  query CourseLearningAnalytics($courseId: ID!) {
    courseLearningAnalytics(courseId: $courseId) {
      runStats { totalRuns activeRuns completedRuns completionRate }
      objectives { objectiveId title required mastered developing needsReview unassessed totalAttempts qualifyingPasses lowConfidenceAttempts passRate lastActivityAt }
      dropOff { staleRunCount }
      generatedAt
    }
  }
`;

/**
 * 课程内容草稿（教研面，H6）。nil 语义（与后端 resolve_course_draft 一致）：
 * courseDraft 为 null = 无权（非 tutor/owner/admin）或课程不存在；
 * 对象非空但 version/content/updatedAt 为 null = 有权但尚无草稿。
 */
export interface CourseDraft {
  courseId: string;
  title: string;
  version: number | null;
  prepState: string | null;
  updatedAt: string | null;
  /** JsonString：draft 的 goals/issues/chapters，结构同 CourseContentDocument */
  content: string | null;
}

export const COURSE_DRAFT: TypedDocumentNode<
  { courseDraft: CourseDraft | null },
  { courseId: string }
> = gql`
  query CourseDraft($courseId: ID!) {
    courseDraft(courseId: $courseId) {
      courseId
      title
      version
      prepState
      updatedAt
      content
    }
  }
`;
