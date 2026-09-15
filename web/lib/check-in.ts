import { client } from "@/lib/apollo-client";
import { timeoutSignal } from "@/lib/timeout-signal";
import {
  CHECK_IN_ENROLLMENT,
  CHECK_IN_EVENT,
  type CheckInEnrollmentPayload,
  type CheckInMethod,
} from "@/lib/graphql/attendance";

/**
 * 现场核销交互层（押金制 KTD5/KTD10；R6、R11；#508 最小核销集；#559 迁壳）。
 *
 * - **码**：6 位数字（后端 `(event_id, check_in_code)` 唯一，前导零有意义 → 全程
 *   字符串，绝不转数字）。主理人手输常带空格/连字符，提交前经同一条归一；
 * - **页面**：工作台壳内 `/w/[slug]/events/[id]/check-in`（#559）——成员强制由
 *   WorkspaceShell 承担（未认证重定向、非成员「不可访问」），event id 来自路由段，
 *   标题/押金旗标走成员读面（`fetchCheckInEvent`：成员可读 closed/成员可见活动）；
 * - **参与者二维码**（#508 选项 A）：承载自定义 payload（`buildCheckInPayload`，
 *   与小程序端 domain/checkin 同文字），扫码方是主理人小程序 `Taro.scanCode`；
 * - 授权与「码无效 / 已核销 / 押金已结算」判定都在后端 mutation（KTD4 fail-closed）。
 */

/** 核销码：6 位数字（KTD5：前导零保留，按字符串处理） */
const CODE_PATTERN = /^\d{6}$/;

/**
 * 核销码归一：剥掉空白与连字符（手输习惯输入「123 456」），
 * 非 6 位数字返回 null（调用方据此给本地提示，不发 mutation）。
 */
export function normalizeCheckInCode(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const compact = raw.replace(/[\s-]/g, "");
  return CODE_PATTERN.test(compact) ? compact : null;
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
  /** 场次标题（成员读面取不到时为 null——不阻塞核销） */
  title: string | null;
  /**
   * 是否押金场（成功文案据此门控：「押金退款已发起」只对押金场成立——
   * 免费/定价场核销不产生退款）。未知按 null 处理：不显示押金文案。
   */
  depositEnabled: boolean | null;
}

/**
 * 核销页的场次读取：成员读面按 id 直取（#559 迁壳后路段恒为 event id，
 * 公开 slug 解析面已退役）。读失败/不存在返回 null——页面给「加载失败 +
 * 重试」，授权判定不在这条读面上（在 mutation）。
 */
export async function fetchCheckInEvent(id: string): Promise<CheckInEventRef | null> {
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
