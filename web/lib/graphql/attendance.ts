import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

/**
 * Admission.Attendance 的手写 GraphQL 面（押金制 KTD4/KTD5；R6、R11；#508 最小核销）。
 *
 * - `checkInEnrollment(eventId, code, method)` 是核销唯一入口：授权（Event 主理人 /
 *   目标 workspace Owner·Admin / 平台管理员）与「码无效 / 已核销 / 押金已结算」
 *   判定全在后端域层，前端只做 code → 文案映射（lib/check-in 的
 *   CHECK_IN_ERROR_CODES + messages errors namespace）；
 * - `checkInEvent` 是核销页的场次解析面（公开读策略：open + public 匿名可读，
 *   成员可读 closed）——只用 id/title 两个字段，不带任何管理面数据。
 */

export type CheckInMethod = "scan" | "manual";

/** 核销成功返回的到场事实（后端 Attendance 行投影） */
export interface CheckInAttendance {
  enrollmentId: string;
  checkedInAt: string;
  method: CheckInMethod;
}

export const CHECK_IN_ENROLLMENT: TypedDocumentNode<
  { checkInEnrollment: MutationResult<CheckInAttendance | null> },
  { eventId: string; code: string; method: CheckInMethod }
> = gql`
  mutation CheckInEnrollment($eventId: ID!, $code: String!, $method: String!) {
    checkInEnrollment(eventId: $eventId, code: $code, method: $method) {
      enrollmentId
      checkedInAt
      method
      errors {
        message
        code
      }
    }
  }
`;

export const CHECK_IN_EVENT: TypedDocumentNode<
  { getEvent: { id: string; title: string } | null },
  { id: string }
> = gql`
  query CheckInEvent($id: ID!) {
    getEvent(id: $id) {
      id
      title
    }
  }
`;
