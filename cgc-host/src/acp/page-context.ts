// page-context.ts — KTD8 的页面上下文块：只带标识，不带 tutor 撰写的文本（如课程、单元标题）。
import { isUuid } from "../security";

/** 单元 id 只认短的 ASCII 标识（tutor 写的标题进不了这里） */
const UNIT_ID = /^[A-Za-z0-9_.-]{1,64}$/;

/**
 * `null` 表示课程总览；`courseVersion` 是页面显示的课程版本号，null 表示未知。返回块内的 JSON，不合法返回 null。
 */
export function pageContext(raw: unknown, courseId: string): string | null {
  if (typeof raw !== "object" || raw === null) return null;
  const { workspaceId, courseVersion, unitId, locale } = raw as Record<string, unknown>;
  const ok =
    isUuid(workspaceId) &&
    (courseVersion === null || (Number.isInteger(courseVersion) && (courseVersion as number) > 0)) &&
    (unitId === null || (typeof unitId === "string" && UNIT_ID.test(unitId))) &&
    (locale === "zh-CN" || locale === "en");
  return ok ? JSON.stringify({ workspace_id: workspaceId, course_id: courseId, course_version: courseVersion, unit_id: unitId, locale }) : null;
}
