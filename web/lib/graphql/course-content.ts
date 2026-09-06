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
