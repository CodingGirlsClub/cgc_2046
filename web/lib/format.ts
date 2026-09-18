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

/**
 * ISO8601 → `<input type="datetime-local">` 值（本地时区，分钟精度）。
 * 空值/不可解析 → ""（input 的未定态）。
 */
export function toLocalInput(datetime?: string | null): string {
	if (!datetime) return "";
	const d = new Date(datetime);
	if (Number.isNaN(d.getTime())) return "";
	const pad = (n: number) => String(n).padStart(2, "0");
	return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * `<input type="datetime-local">` 值 → UTC ISO8601；空值/不可解析 → null（= 未定）。
 *
 * 注意精度：输入只到分钟，回读同一值再提交会把库里的秒截断——表单必须做
 * 脏检查（未改动不下发），见 offering-pages 的 registrationDeadlineDirty 纪律。
 */
export function fromLocalInput(value: string): string | null {
	if (!value) return null;
	const d = new Date(value);
	return Number.isNaN(d.getTime()) ? null : d.toISOString();
}
