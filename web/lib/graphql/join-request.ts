import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

/**
 * B-3 JoinRequest GraphQL 契约（对齐 backend/priv/graphql/schema.graphql）。
 *
 * 关键约定：
 * - JoinRequest type：{ id, workspaceId, userId, status, message?, approvedBy?,
 *   approvedAt?, rejectionReason?, approvalDeadline?, expiredAt? }
 * - joinRequests(query)：keyset 分页，filter 支持 workspaceId/status/userId 过滤。
 * - create/approve/reject mutation 返回 { result, errors } 两段式（MutationResult）。
 * - joinWorkspace(workspaceId)：generic action mutation（写操作语义），直接加入
 *   open workspace，返回裸 Workspace（无 result/errors 包装，失败走 top-level
 *   GraphQL error）。放本文件因 requests.ts 是其唯一消费方。
 */

/* ---------------- 类型 ---------------- */

export type JoinRequestStatus = "pending" | "approved" | "rejected" | "expired";

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

export interface CreateJoinRequestInput {
	/** 申请留言（可选） */
	message?: string | null;
	/** 目标工作台 ID */
	workspaceId: string;
	/** 申请人 ID */
	userId: string;
}

export interface ApproveJoinRequestInput {
	roleNames?: string[] | null;
}

export interface RejectJoinRequestInput {
	rejectionReason?: string | null;
}

export type CreateJoinRequestResultData = MutationResult<JoinRequest>;
export type ApproveJoinRequestResultData = MutationResult<JoinRequest>;
export type RejectJoinRequestResultData = MutationResult<JoinRequest>;

/** joinRequests 分页对象 */
export interface JoinRequestConnection {
	count: number;
	results: JoinRequest[];
	startKeyset?: string | null;
	endKeyset?: string | null;
}

/** joinRequests filter */
export interface JoinRequestsFilter {
	workspaceId?: { eq?: string } | null;
	status?: { eq?: string } | null;
	userId?: { eq?: string } | null;
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
 * joinWorkspace：直接加入公开工作台（join_policy==:open）。
 * 后端为 generic action，GraphQL 暴露为 mutation（写操作语义）。
 * 参数包进 JoinWorkspaceInput（AshGraphql mutation 惯例），返回非空 Workspace。
 *
 * 与 create/approve/reject 等 create/update mutation 不同：generic action 不生成
 * { result, errors } 包装类型，返回裸 Workspace；失败时错误以 top-level GraphQL error 返回，
 * 前端从抛出的错误对象（Apollo CombinedGraphQLErrors）提取 message，而非读 data.xxx.errors。
 */
export const JOIN_WORKSPACE: TypedDocumentNode<
	{ joinWorkspace: { id: string; slug: string; name: string } },
	{ workspaceId: string }
> = gql`
  mutation JoinWorkspace($workspaceId: ID!) {
    joinWorkspace(input: { workspaceId: $workspaceId }) {
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

/* ---------------- 状态展示辅助 ---------------- */

export const JOIN_REQUEST_STATUS_LABEL: Record<JoinRequestStatus, string> = {
	pending: "申请审批中",
	approved: "已通过",
	rejected: "已拒绝",
	expired: "已过期",
};
