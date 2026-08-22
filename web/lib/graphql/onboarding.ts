import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * 首公里 onboarding GraphQL 契约（plan 2026-08-22 first-mile-onboarding，U2）。
 *
 * - `me.onboardingInvitationDismissedAt`：邀请拒绝时间（KTD2 服务端持久化，
 *   跨设备一致；null = 未拒绝）。字段由后端 U1 提供（见 schema.graphql User 类型）。
 * - `dismissOnboardingInvitation`：拒绝邀请（幂等保留首次拒绝时间戳，仅本人）。
 *   返回 User 直接类型（同 updateMyLocale 风格，无 payload 信封）。
 */

/* ---------------- 类型 ---------------- */

/** me 查询中本功能关心的最小字段集 */
export interface OnboardingMe {
  id: string;
  /** 首公里接入邀请的拒绝时间；null = 未拒绝 */
  onboardingInvitationDismissedAt: string | null;
}

/* ---------------- Query / Mutation TypedDocumentNode ---------------- */

/** 当前用户的邀请拒绝态查询 */
export const ME_ONBOARDING: TypedDocumentNode<
  { me: OnboardingMe | null },
  Record<string, never>
> = gql`
  query MeOnboarding {
    me {
      id
      onboardingInvitationDismissedAt
    }
  }
`;

/** 拒绝首公里接入邀请（每次登录弹直到明确拒绝；幂等，仅本人） */
export const DISMISS_ONBOARDING_INVITATION: TypedDocumentNode<
  { dismissOnboardingInvitation: OnboardingMe | null },
  Record<string, never>
> = gql`
  mutation DismissOnboardingInvitation {
    dismissOnboardingInvitation {
      id
      onboardingInvitationDismissedAt
    }
  }
`;
