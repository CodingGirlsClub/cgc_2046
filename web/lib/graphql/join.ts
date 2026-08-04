import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * B-3 JoinRequest / Invitation GraphQL 契约（对齐 backend/priv/graphql/schema.graphql）。
 *
 * 关键约定：
 * - JoinRequest type：{ id, workspaceId, userId, status, message?, approvedBy?,
 *   approvedAt?, rejectionReason?, approvalDeadline?, expiredAt? }
 * - Invitation type：{ id, workspaceId, tokenHash, plainToken?, inviterId,
 *   targetEmail?, preauthorizedRoleNames?, expiresAt?, status, acceptedBy?,
 *   acceptedAt?, workspaceName?, workspaceSlug?, workspaceJoinPolicy? }
 * - joinRequests(query)：keyset 分页，filter 支持 workspaceId/status 过滤。
 * - invitations(query)：keyset 分页，filter 支持 workspaceId/status 过滤。
 * - validateInvitation(token)：返回 Invitation（含 workspace 预览字段）。
 * - joinWorkspace(workspaceId)：query（非 mutation），直接加入 open workspace。
 */

/* ---------------- 类型 ---------------- */

export type JoinRequestStatus = "pending" | "approved" | "rejected" | "expired";

export type InvitationStatus = "active" | "used" | "revoked" | "expired";

export interface JoinRequest {
	id: string;
	/** 所属工作台（租户）ID */
	workspaceId: string;
	/** 申请人（全局用户）ID */
	userId: string;
	/** 申请状态 */
	status: JoinRequestStatus;
	/** 申请留言（可选） */
	message?: string | null;
	/** 审批人（全局用户）ID */
	approvedBy?: string | null;
	/** 审批时间 */
	approvedAt?: string | null;
	/** 拒绝原因（可选） */
	rejectionReason?: string | null;
	/** 审批截止时间（默认 created_at + 7 天） */
	approvalDeadline?: string | null;
	/** 过期时间 */
	expiredAt?: string | null;
}

export interface Invitation {
	id: string;
	/** 所属工作台（租户）ID */
	workspaceId: string;
	/** 邀请令牌的 SHA256 哈希 */
	tokenHash: string;
	/** 明文邀请令牌（仅创建时返回） */
	plainToken?: string | null;
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

export interface MutationError {
	message?: string | null;
	code?: string | null;
}

export interface CreateJoinRequestInput {
	/** 申请留言（可选） */
	message?: string | null;
	/** 目标工作台 ID */
	workspaceId: string;
	/** 申请人 ID */
	userId: string;
}

export interface CreateJoinRequestResultData {
	result: JoinRequest | null;
	errors: MutationError[];
}

export interface ApproveJoinRequestInput {
	roleNames?: string[] | null;
}

export interface ApproveJoinRequestResultData {
	result: JoinRequest | null;
	errors: MutationError[];
}

export interface RejectJoinRequestInput {
	rejectionReason?: string | null;
}

export interface RejectJoinRequestResultData {
	result: JoinRequest | null;
	errors: MutationError[];
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

export interface CreateInvitationResultData {
	result: Invitation | null;
	errors: MutationError[];
}

export interface RevokeInvitationResultData {
	result: Invitation | null;
	errors: MutationError[];
}

export interface AcceptInvitationResultData {
	result: Invitation | null;
	errors: MutationError[];
}

/** joinRequests 分页对象 */
export interface JoinRequestConnection {
	count: number;
	results: JoinRequest[];
	startKeyset?: string | null;
	endKeyset?: string | null;
}

/** invitations 分页对象 */
export interface InvitationConnection {
	count: number;
	results: Invitation[];
	startKeyset?: string | null;
	endKeyset?: string | null;
}

/** joinRequests filter */
export interface JoinRequestsFilter {
	workspaceId?: { eq?: string } | null;
	status?: { eq?: string } | null;
	userId?: { eq?: string } | null;
}

/** invitations filter */
export interface InvitationsFilter {
	workspaceId?: { eq?: string } | null;
	status?: { eq?: string } | null;
}

/* ---------------- Query / Mutation TypedDocumentNode ---------------- */

/**
 * joinRequests：加入申请列表（keyset 分页）。
 * 申请人仅见自己；Owner/Admin 见全部。
 */
export const JOIN_REQUESTS: TypedDocumentNode<
	{ joinRequests: JoinRequestConnection },
	{
		filter: JoinRequestsFilter;
		first?: number;
		after?: string;
	}
> = gql`
  query JoinRequests($filter: JoinRequestFilterInput!, $first: Int, $after: String) {
    joinRequests(filter: $filter, first: $first, after: $after) {
      count
      results {
        id
        workspaceId
        userId
        status
        message
        approvedBy
        approvedAt
        rejectionReason
        approvalDeadline
        expiredAt
      }
      startKeyset
      endKeyset
    }
  }
`;

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
  query Invitations($filter: InvitationFilterInput!, $first: Int, $after: String) {
    invitations(filter: $filter, first: $first, after: $after) {
      count
      results {
        id
        workspaceId
        tokenHash
        plainToken
        inviterId
        targetEmail
        preauthorizedRoleNames
        expiresAt
        status
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
 * joinWorkspace：直接加入公开工作台（join_policy==:open）。
 * 后端为 query（非 mutation），返回 Workspace。
 */
export const JOIN_WORKSPACE: TypedDocumentNode<
	{ joinWorkspace: { id: string; slug: string; name: string } | null },
	{ workspaceId: string }
> = gql`
  query JoinWorkspace($workspaceId: ID!) {
    joinWorkspace(workspaceId: $workspaceId) {
      id
      slug
      name
    }
  }
`;

/**
 * createJoinRequest：提交加入申请。
 */
export const CREATE_JOIN_REQUEST: TypedDocumentNode<
	{ createJoinRequest: CreateJoinRequestResultData },
	{ input: CreateJoinRequestInput }
> = gql`
  mutation CreateJoinRequest($input: CreateJoinRequestInput!) {
    createJoinRequest(input: $input) {
      result {
        id
        workspaceId
        userId
        status
        message
        approvalDeadline
      }
      errors {
        message
        code
      }
    }
  }
`;

/**
 * approveJoinRequest：审批通过加入申请（Owner/Admin）。
 */
export const APPROVE_JOIN_REQUEST: TypedDocumentNode<
	{ approveJoinRequest: ApproveJoinRequestResultData },
	{ id: string; input: ApproveJoinRequestInput }
> = gql`
  mutation ApproveJoinRequest($id: ID!, $input: ApproveJoinRequestInput!) {
    approveJoinRequest(id: $id, input: $input) {
      result {
        id
        status
        approvedBy
        approvedAt
      }
      errors {
        message
        code
      }
    }
  }
`;

/**
 * rejectJoinRequest：拒绝加入申请（Owner/Admin）。
 */
export const REJECT_JOIN_REQUEST: TypedDocumentNode<
	{ rejectJoinRequest: RejectJoinRequestResultData },
	{ id: string; input: RejectJoinRequestInput }
> = gql`
  mutation RejectJoinRequest($id: ID!, $input: RejectJoinRequestInput!) {
    rejectJoinRequest(id: $id, input: $input) {
      result {
        id
        status
        rejectionReason
      }
      errors {
        message
        code
      }
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
        plainToken
        targetEmail
        preauthorizedRoleNames
        expiresAt
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
	{ id: string }
> = gql`
  mutation AcceptInvitation($id: ID!) {
    acceptInvitation(id: $id) {
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

export const JOIN_REQUEST_STATUS_LABEL: Record<JoinRequestStatus, string> = {
	pending: "申请审批中",
	approved: "已通过",
	rejected: "已拒绝",
	expired: "已过期",
};

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
