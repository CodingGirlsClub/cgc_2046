/**
 * 共享展示格式化工具。
 *
 * P1 后端 joinedAt 返回 ISO8601（如 "2026-08-02T03:00:00Z"），
 * 设计稿展示为中文年月（"2026 年 8 月"）。真实值未返回时原样返回，
 * 兼容 mock / 旧数据的 "2024 年 3 月" 中文格式。
 */

/** 把 ISO/日期字符串格式化为 "YYYY 年 M 月"；无法解析时原样返回。 */
export function formatJoinedDate(value?: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return `${date.getFullYear()} 年 ${date.getMonth() + 1} 月`;
}
