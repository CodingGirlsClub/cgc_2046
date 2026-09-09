/**
 * 「添加日历」（P1a）：报名成功卡的活动日程导出。纯前端零依赖——
 * Google Calendar 走 calendar/render TEMPLATE 链接；.ics 走纯文本拼接 +
 * Blob 下载。时间一律转 UTC 的 `YYYYMMDDTHHMMSSZ` 基本格式。
 */

export interface CalendarEventInput {
  title: string;
  /** 开始时间（ISO8601） */
  startsAt: string;
  /** 结束时间（ISO8601；缺省时按开始后 1 小时兜底） */
  endsAt?: string | null;
  /** 地点文本（formatVenue 拼接结果；无则省略） */
  venue?: string | null;
  /** 备注正文（无则省略） */
  details?: string | null;
}

/** Date → ICS/Google 公用的 UTC 基本格式 `YYYYMMDDTHHMMSSZ` */
function formatUtcBasic(date: Date): string {
  return date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

function resolveRange(input: CalendarEventInput): { start: Date; end: Date } {
  const start = new Date(input.startsAt);
  const end =
    input.endsAt != null
      ? new Date(input.endsAt)
      : new Date(start.getTime() + 60 * 60 * 1000);
  return { start, end };
}

/** Google Calendar「创建事件」预填链接（新标签页打开，保存由 Google 侧完成） */
export function googleCalendarUrl(input: CalendarEventInput): string {
  const { start, end } = resolveRange(input);
  const params = new URLSearchParams({
    action: "TEMPLATE",
    text: input.title,
    dates: `${formatUtcBasic(start)}/${formatUtcBasic(end)}`,
  });
  if (input.venue) params.set("location", input.venue);
  if (input.details) params.set("details", input.details);
  return `https://calendar.google.com/calendar/render?${params.toString()}`;
}

/** ICS 文本值转义：反斜杠/分号/逗号前补 `\`，换行折叠为 `\n` 字面量 */
export function escapeIcsText(value: string): string {
  return value
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r?\n/g, "\\n");
}

/** 单事件 VCALENDAR 文本（CRLF 行尾；`now` 可注入以稳定 DTSTAMP） */
export function buildIcs(
  input: CalendarEventInput,
  now: Date = new Date(),
): string {
  const { start, end } = resolveRange(input);
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//CodingGirlsClub//CGC 2046//ZH",
    "BEGIN:VEVENT",
    `UID:cgc-${start.getTime()}-${escapeIcsText(input.title)}@cgc2046`,
    `DTSTAMP:${formatUtcBasic(now)}`,
    `DTSTART:${formatUtcBasic(start)}`,
    `DTEND:${formatUtcBasic(end)}`,
    `SUMMARY:${escapeIcsText(input.title)}`,
  ];
  if (input.venue) lines.push(`LOCATION:${escapeIcsText(input.venue)}`);
  if (input.details) lines.push(`DESCRIPTION:${escapeIcsText(input.details)}`);
  lines.push("END:VEVENT", "END:VCALENDAR");
  return lines.join("\r\n") + "\r\n";
}

/** 生成 .ics 并触发浏览器下载（仅在事件分支成功卡由用户点击触发） */
export function downloadIcs(input: CalendarEventInput): void {
  const ics = buildIcs(input);
  const blob = new Blob([ics], { type: "text/calendar;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = `${input.title || "event"}.ics`;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}
