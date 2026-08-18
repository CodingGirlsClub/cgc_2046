/**
 * 共享展示格式化工具。
 *
 * P1 后端 joinedAt 返回 ISO8601（如 "2026-08-02T03:00:00Z"），
 * 设计稿展示为中文年月（"2026 年 8 月"）。真实值未返回时原样返回，
 * 兼容 mock / 旧数据的 "2024 年 3 月" 中文格式。
 */

/** 把 ISO/日期字符串格式化为「年/月」：zh-CN → "2026 年 8 月"（与既有展示逐字节一致）；其它 locale 用 Intl。无法解析时原样返回。 */
export function formatJoinedDate(
  value?: string | null,
  locale: string = "zh-CN",
): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  if (locale === "zh-CN") {
    return `${date.getFullYear()} 年 ${date.getMonth() + 1} 月`;
  }
  return new Intl.DateTimeFormat(locale, {
    year: "numeric",
    month: "long",
  }).format(date);
}

/** 把 ISO/日期字符串格式化为 "YYYY-MM-DD HH:mm"（本地时区）；空值 "—"，无法解析原样返回。 */
export function formatDateTime(value?: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
