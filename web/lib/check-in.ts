import { client } from "@/lib/apollo-client";
import { routing } from "@/i18n/routing";
import { fetchPublicOffering } from "@/lib/public-offerings";
import {
  CHECK_IN_ENROLLMENT,
  CHECK_IN_EVENT,
  type CheckInAttendance,
  type CheckInMethod,
} from "@/lib/graphql/attendance";
import type { MutationResult } from "@/lib/graphql/shared";

/**
 * 现场核销交互层（押金制 KTD5/KTD10；R6、R11；#508 最小核销集）。
 *
 * - **码**：6 位数字（后端 `(event_id, check_in_code)` 唯一，前导零有意义 → 全程
 *   字符串，绝不转数字）。URL 预填与主理人手输共用同一条归一（手输常带空格）；
 * - **核销 URL**：`/events/<slug|eventId>/check-in?code=NNNNNN`——主理人链接用公开
 *   slug（U9 主理人卡「复制核销页链接」），参与者二维码用 event id（`/participations`
 *   报名行只有 eventId，没有 slug）；核销页两种路段都认（见 resolveCheckInEvent）；
 * - **场次解析**：提交需要 eventId。slug 走公开读面（open + public 匿名可读，成员可读
 *   closed），id 直接用；标题只作展示——取不到不阻塞核销，授权与「码无效 / 已核销 /
 *   押金已结算」判定都在后端 mutation（KTD4）。
 */

/** 核销码：6 位数字（KTD5：前导零保留，按字符串处理） */
const CODE_PATTERN = /^\d{6}$/;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * 核销码归一：剥掉空白与连字符（手输习惯输入「123 456」/二维码 URL 编码残留），
 * 非 6 位数字返回 null（调用方据此给本地提示，不发 mutation）。
 */
export function normalizeCheckInCode(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const compact = raw.replace(/[\s-]/g, "");
  return CODE_PATTERN.test(compact) ? compact : null;
}

/**
 * 核销 URL（二维码承载；KTD5）。locale 前缀按 i18n/routing 的 "as-needed" 口径：
 * 默认 locale（zh-CN）无前缀，其余加 `/<locale>`。
 */
export function buildCheckInPath(
  locale: string,
  eventSegment: string,
  code: string,
): string {
  const prefix = locale === routing.defaultLocale ? "" : `/${locale}`;
  return `${prefix}/events/${encodeURIComponent(eventSegment)}/check-in?code=${encodeURIComponent(code)}`;
}

export interface CheckInEventRef {
  id: string;
  /** 场次标题（公开读面取不到时为 null——不阻塞核销） */
  title: string | null;
}

/**
 * 核销页的场次解析：路段是 slug（主理人链接）或 event id（参与者二维码）。
 *
 * - UUID 路段 → 直接用 id，标题尽力而为（非公开/已结束场次的匿名读不到标题，
 *   但主理人仍能核销）；
 * - 其他路段 → 公开 slug 读面解析出 id/title；解析不到返回 null（页面给
 *   「场次不存在或不可访问」+ 重试，不静默用 slug 当 id 提交）。
 */
export async function resolveCheckInEvent(
  segment: string,
): Promise<CheckInEventRef | null> {
  if (!segment) return null;
  if (UUID_PATTERN.test(segment)) {
    return (await fetchEventById(segment)) ?? { id: segment, title: null };
  }
  const row = await fetchPublicOffering(segment, "event");
  return row ? { id: row.id, title: row.title } : null;
}

async function fetchEventById(id: string): Promise<CheckInEventRef | null> {
  try {
    const { data } = await client.query({
      query: CHECK_IN_EVENT,
      variables: { id },
      fetchPolicy: "network-only",
    });
    return data?.getEvent
      ? { id: data.getEvent.id, title: data.getEvent.title }
      : null;
  } catch {
    // 标题是展示增强：读失败（网络/权限）不阻断核销主流程
    return null;
  }
}

/**
 * 提交核销。业务失败（码无效 / 已核销 / 押金已结算 / 无权限）进 `errors`（按 code
 * 查文案），网络类故障按 reject 抛出——两者在页面上是不同反馈（后者可原样重试）。
 */
export async function checkInEnrollment(input: {
  eventId: string;
  code: string;
  method: CheckInMethod;
}): Promise<MutationResult<CheckInAttendance | null>> {
  const { data } = await client.mutate({
    mutation: CHECK_IN_ENROLLMENT,
    variables: input,
  });
  return data?.checkInEnrollment ?? { result: null, errors: [] };
}
