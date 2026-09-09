"use client";

/**
 * 「添加日历」区（P1a）：活动报名成功卡内的日程导出——Google Calendar
 * 预填链接（新标签页）+ .ics 下载。无 startsAt 的活动不渲染（调用方已判空，
 * 此处再兜底一层）。i18n 用 common 命名空间，供公开详情页与工作台详情页共用。
 */

import { useTranslations } from "next-intl";
import { downloadIcs, googleCalendarUrl } from "@/lib/calendar";

export default function AddToCalendar({
  eventId,
  title,
  startsAt,
  endsAt,
  venue,
}: {
  /** offering 稳定 ID——ICS UID 身份来源（review F2） */
  eventId: string;
  title: string;
  startsAt: string | null | undefined;
  endsAt?: string | null;
  venue?: string | null;
}) {
  const t = useTranslations("common");
  if (!startsAt) return null;
  const input = { id: eventId, title, startsAt, endsAt, venue };
  return (
    <div className="flex flex-wrap items-center gap-3" data-testid="add-to-calendar">
      <a
        href={googleCalendarUrl(input)}
        target="_blank"
        rel="noopener noreferrer"
        className="text-[13px] text-accent hover:underline"
      >
        {t("addToGoogleCalendar")}
      </a>
      <button
        type="button"
        className="text-[13px] text-accent hover:underline"
        onClick={() => downloadIcs(input)}
      >
        {t("downloadIcs")}
      </button>
    </div>
  );
}
