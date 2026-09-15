import { client } from "@/lib/apollo-client";
import { timeoutSignal } from "@/lib/timeout-signal";
import { routing } from "@/i18n/routing";
import { fetchPublicOffering } from "@/lib/public-offerings";
import {
  CHECK_IN_ENROLLMENT,
  CHECK_IN_EVENT,
  type CheckInEnrollmentPayload,
  type CheckInMethod,
} from "@/lib/graphql/attendance";

/**
 * 现场核销交互层（押金制 KTD5/KTD10；R6、R11；#508 最小核销集）。
 *
 * - **码**：6 位数字（后端 `(event_id, check_in_code)` 唯一，前导零有意义 → 全程
 *   字符串，绝不转数字）。URL 预填与主理人手输共用同一条归一（手输常带空格）；
 * - **核销 URL**：`/events/<slug|eventId>/check-in?code=NNNNNN`——主理人链接用公开
 *   slug（U9 主理人卡「复制核销页链接」）；核销页 slug / id 两种路段都认
 *   （见 resolveCheckInEvent）；
 * - **参与者二维码**（#508 选项 A）：承载自定义 payload（`buildCheckInPayload`，
 *   与小程序端 domain/checkin 同文字），扫码方是主理人小程序 `Taro.scanCode`——
 *   payload 不再是 URL，「原生扫码打不开相对路径」随之消解；
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
 * 核销 URL（主理人核销页链接；KTD5）。locale 前缀按 i18n/routing 的 "as-needed"
 * 口径：默认 locale（zh-CN）无前缀，其余加 `/<locale>`。
 */
export function buildCheckInPath(
  locale: string,
  eventSegment: string,
  code: string,
): string {
  const prefix = locale === routing.defaultLocale ? "" : `/${locale}`;
  return `${prefix}/events/${encodeURIComponent(eventSegment)}/check-in?code=${encodeURIComponent(code)}`;
}

/**
 * 参与者二维码 payload（#508 选项 A）：自定义格式而非 URL——扫码方是主理人
 * 小程序 `Taro.scanCode`（解析器 = miniprogram/src/domain/checkin.ts 的
 * parseCheckInScan，两端同文字互指）。eventId 供主理人端交叉校验。
 */
export function buildCheckInPayload(eventId: string, code: string): string {
  return `cgc2046:checkin:${eventId}:${code}`;
}

export interface CheckInEventRef {
  id: string;
  /** 场次标题（公开读面取不到时为 null——不阻塞核销） */
  title: string | null;
  /**
   * 是否押金场（成功文案据此门控：「押金退款已发起」只对押金场成立——
   * 免费/定价场核销不产生退款）。未知（公开读面不可得）按 null 处理：
   * 不显示押金文案。
   */
  depositEnabled: boolean | null;
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
    return (
      (await fetchEventById(segment)) ?? {
        id: segment,
        title: null,
        depositEnabled: null,
      }
    );
  }
  const row = await fetchPublicOffering(segment, "event");
  return row
    ? { id: row.id, title: row.title, depositEnabled: row.depositEnabled ?? null }
    : null;
}

async function fetchEventById(id: string): Promise<CheckInEventRef | null> {
  try {
    const { data } = await client.query({
      query: CHECK_IN_EVENT,
      variables: { id },
      fetchPolicy: "network-only",
    });
    return data?.getEvent
      ? {
          id: data.getEvent.id,
          title: data.getEvent.title,
          depositEnabled: data.getEvent.depositEnabled ?? null,
        }
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
}): Promise<CheckInEnrollmentPayload> {
  const { data } = await client.mutate({
    mutation: CHECK_IN_ENROLLMENT,
    variables: input,
    // 现场网络可能挂起：15s 超时让按钮回到可重试，而不是永停「提交中」
    context: { fetchOptions: { signal: timeoutSignal() } },
  });
  return (
    data?.checkInEnrollment ?? {
      enrollmentId: null,
      checkedInAt: null,
      method: null,
      depositRefund: null,
      errors: [],
    }
  );
}
