import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationError, MutationResult } from "./shared";

/**
 * B-3 Invitation GraphQL 契约（对齐 backend/priv/graphql/schema.graphql）。
 *
 * 关键约定：
 * - Invitation type：{ id, workspaceId, tokenHash, inviterId,
 *   targetEmail?, preauthorizedRoleNames?, expiresAt?, status, acceptedBy?,
 *   acceptedAt?, workspaceName?, workspaceSlug?, workspaceJoinPolicy? }
 * - createInvitation mutation result 额外含 metadata.plainToken（明文令牌仅创建时
 *   一次性返回，不落库）。
 * - invitations(query)：keyset 分页，filter 支持 workspaceId/status 过滤。
 * - validateInvitation(token)：返回 Invitation（含 workspace 预览字段）。
 */

/* ---------------- 类型 ---------------- */

export type InvitationStatus = "active" | "used" | "revoked" | "expired";

export interface Invitation {
  id: string;
  /** 所属工作台（租户）ID */
  workspaceId: string;
  /** 邀请令牌的 SHA256 哈希 */
  tokenHash: string;
  /** 邀请人（全局用户）ID */
  inviterId: string;
  /** 目标邮箱（空=公开链接） */
  targetEmail?: string | null;
  /** 预授权角色名数组（可选） */
  preauthorizedRoleNames?: string[] | null;
  /** 过期时间（可选） */
  expiresAt?: string | null;
  /** 邀请状态 */
  status: InvitationStatus;
  /** 读时派生状态：expires_at < now 时为 "expired"，否则同 status；优先于 status 使用 */
  effectiveStatus?: InvitationStatus | null;
  /** 接受人（全局用户）ID */
  acceptedBy?: string | null;
  /** 接受时间 */
  acceptedAt?: string | null;
  /** 工作台名称（validateInvitation 返回） */
  workspaceName?: string | null;
  /** 工作台 slug（validateInvitation 返回） */
  workspaceSlug?: string | null;
  /** 工作台加入策略（validateInvitation 返回） */
  workspaceJoinPolicy?: string | null;
}

export interface CreateInvitationInput {
  /** 目标邮箱（空=公开链接） */
  targetEmail?: string | null;
  /** 预授权角色名数组（可选） */
  preauthorizedRoleNames?: string[] | null;
  /** 过期时间（可选） */
  expiresAt?: string | null;
  /** 目标工作台 ID */
  workspaceId: string;
  /** 邀请人 ID */
  inviterId: string;
}

export interface CreateInvitationMetadata {
  /** 明文邀请令牌（仅创建时返回一次，不落库） */
  plainToken: string;
}

/**
 * createInvitation 返回包装：在标准 MutationResult 基础上多一个 metadata
 * （明文令牌仅创建时一次性返回，列表 query 不含此字段）。
 */
export interface CreateInvitationResultData {
  result: Invitation | null;
  errors: MutationError[];
  /** 明文邀请令牌（仅创建时一次性返回，列表 query 不含此字段） */
  metadata?: CreateInvitationMetadata | null;
}

export type RevokeInvitationResultData = MutationResult<Invitation>;
export type AcceptInvitationResultData = MutationResult<Invitation>;

/** invitations 分页对象 */
export interface InvitationConnection {
  count: number;
  results: Invitation[];
  startKeyset?: string | null;
  endKeyset?: string | null;
}

/** invitations filter */
export interface InvitationsFilter {
  workspaceId?: { eq?: string } | null;
  status?: { eq?: string } | null;
}

/* ---------------- Query / Mutation TypedDocumentNode ---------------- */

/**
 * invitations：邀请列表（keyset 分页）。
 * 邀请人仅见自己；Owner/Admin 见全部。
 */
export const INVITATIONS: TypedDocumentNode<
  { invitations: InvitationConnection },
  {
    filter: InvitationsFilter;
    first?: number;
    after?: string;
  }
> = gql`
  query Invitations(
    $filter: InvitationFilterInput!
    $first: Int
    $after: String
  ) {
    invitations(filter: $filter, first: $first, after: $after) {
      count
      results {
        id
        workspaceId
        tokenHash
        inviterId
        targetEmail
        preauthorizedRoleNames
        expiresAt
        status
        effectiveStatus
        acceptedBy
        acceptedAt
      }
      startKeyset
      endKeyset
    }
  }
`;

/**
 * validateInvitation：校验邀请 token，返回邀请信息 + 工作台预览。
 * 前端不调 getWorkspace，只调此 query（决策 8）。
 */
export const VALIDATE_INVITATION: TypedDocumentNode<
  { validateInvitation: Invitation | null },
  { token: string }
> = gql`
  query ValidateInvitation($token: String!) {
    validateInvitation(token: $token) {
      id
      workspaceId
      status
      effectiveStatus
      targetEmail
      preauthorizedRoleNames
      expiresAt
      workspaceName
      workspaceSlug
      workspaceJoinPolicy
    }
  }
`;

/**
 * createInvitation：创建邀请（Owner/Admin/Volunteer）。
 */
export const CREATE_INVITATION: TypedDocumentNode<
  { createInvitation: CreateInvitationResultData },
  { input: CreateInvitationInput }
> = gql`
  mutation CreateInvitation($input: CreateInvitationInput!) {
    createInvitation(input: $input) {
      result {
        id
        workspaceId
        targetEmail
        preauthorizedRoleNames
        expiresAt
        status
      }
      metadata {
        plainToken
      }
      errors {
        message
        code
      }
    }
  }
`;

/**
 * revokeInvitation：撤销邀请（邀请人本人或 Owner/Admin）。
 */
export const REVOKE_INVITATION: TypedDocumentNode<
  { revokeInvitation: RevokeInvitationResultData },
  { id: string }
> = gql`
  mutation RevokeInvitation($id: ID!) {
    revokeInvitation(id: $id) {
      result {
        id
        status
      }
      errors {
        message
        code
      }
    }
  }
`;

/**
 * acceptInvitation：接受邀请→建 Membership + 预授权角色入座。
 */
export const ACCEPT_INVITATION: TypedDocumentNode<
  { acceptInvitation: AcceptInvitationResultData },
  { id: string; token: string }
> = gql`
  mutation AcceptInvitation($id: ID!, $token: String!) {
    acceptInvitation(id: $id, input: { token: $token }) {
      result {
        id
        status
        acceptedBy
        acceptedAt
      }
      errors {
        message
        code
      }
    }
  }
`;

/* ---------------- 状态展示辅助 ---------------- */

export const INVITATION_STATUS_LABEL: Record<InvitationStatus, string> = {
  active: "有效",
  used: "已使用",
  revoked: "已撤销",
  expired: "已过期",
};

export const INVITATION_STATUS_CLASS: Record<InvitationStatus, string> = {
  active: "invitation-status--active",
  used: "invitation-status--used",
  revoked: "invitation-status--revoked",
  expired: "invitation-status--expired",
};
