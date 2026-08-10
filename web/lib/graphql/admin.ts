import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationError } from "./shared";
import type { JoinPolicy } from "./workspace";

/**
 * Platform Admin Dashboard GraphQL 契约（对齐后端 Phase 5 schema commit ca89719）。
 *
 * 关键约定：
 * - listUsers / listWorkspaces / listWorkspaceApplications 返回裸对象数组，
 *   分页参数 first（默认 50）/ after（offset 字符串）。
 * - listWorkflowRuns 复用 workflow.ts 既有 LIST_WORKFLOW_RUNS（Phase 5 决定不手写，
 *   WorkflowRun 自动 query + platform_admin read policy）。
 * - approve/rejectWorkspaceApplication + createWorkspace 为 AshGraphql 自动生成，
 *   返回标准 { result, errors } 信封；createWorkspace 的 metadata 携带
 *   ownerInvitationToken（仅创建时返回一次）。
 */

/* ---------------- 类型（对齐 backend/priv/graphql/schema.graphql） ---------------- */

export interface AdminUser {
	id: string;
	email?: string | null;
	displayName?: string | null;
	isPlatformAdmin: boolean;
	insertedAt: string;
	workspaceMembershipCount?: number | null;
}

/** 与 workspace.ts 的 JoinPolicy 同构（单源：workspace.ts） */
export type AdminJoinPolicy = JoinPolicy;

export interface AdminWorkspace {
	id: string;
	slug: string;
	name: string;
	joinPolicy: AdminJoinPolicy;
	sponsorshipEnabled: boolean;
	insertedAt: string;
	memberCount: number;
}

export type AdminApplicationStatus = "pending" | "approved" | "rejected" | "expired";

export interface AdminWorkspaceApplication {
	id: string;
	applicantId: string;
	name: string;
	slug: string;
	purpose: string;
	status: AdminApplicationStatus;
	rejectionReason?: string | null;
	insertedAt: string;
}

export interface AdminToolCallLog {
	id: string;
	userId: string;
	tool: string;
	resultStatus: string;
	errorMessage?: string | null;
	latencyMs?: number | null;
	insertedAt: string;
}

export interface AdminPendingOperation {
	id: string;
	userId: string;
	tool: string;
	summary: string;
	status: string;
	insertedAt: string;
}

export interface AdminSignalLog {
	id: string;
	workspaceId: string;
	signalType: string;
	insertedAt: string;
}

/** promoteUser/demoteUser 返回（set_platform_admin 结果信封） */
export interface AdminUserPayload {
	id: string | null;
	email?: string | null;
	isPlatformAdmin?: boolean | null;
	errors: MutationError[];
}

/** admin 列表查询通用分页参数（after = offset 字符串） */
export interface AdminListArgs {
	first?: number;
	after?: string;
}

/* ---------------- 真实 query / mutation ---------------- */

export const LIST_USERS: TypedDocumentNode<
	{ listUsers: AdminUser[] },
	{ search?: string | null; first?: number; after?: string } & AdminListArgs
> = gql`
  query ListUsers($search: String, $first: Int, $after: String) {
    listUsers(search: $search, first: $first, after: $after) {
      id
      email
      displayName
      isPlatformAdmin
      insertedAt
      workspaceMembershipCount
    }
  }
`;

export const LIST_WORKSPACES: TypedDocumentNode<
	{ listWorkspaces: AdminWorkspace[] },
	{ search?: string | null; first?: number; after?: string } & AdminListArgs
> = gql`
  query ListWorkspaces($search: String, $first: Int, $after: String) {
    listWorkspaces(search: $search, first: $first, after: $after) {
      id
      slug
      name
      joinPolicy
      sponsorshipEnabled
      insertedAt
      memberCount
    }
  }
`;

export const LIST_WORKSPACE_APPLICATIONS: TypedDocumentNode<
	{ listWorkspaceApplications: AdminWorkspaceApplication[] },
	{ status?: string | null; first?: number; after?: string } & AdminListArgs
> = gql`
  query ListWorkspaceApplications($status: String, $first: Int, $after: String) {
    listWorkspaceApplications(status: $status, first: $first, after: $after) {
      id
      applicantId
      name
      slug
      purpose
      status
      rejectionReason
      insertedAt
    }
  }
`;

export const MY_WORKSPACE_APPLICATIONS: TypedDocumentNode<
	{ myWorkspaceApplications: AdminWorkspaceApplication[] },
	Record<string, never>
> = gql`
  query MyWorkspaceApplications {
    myWorkspaceApplications {
      id
      applicantId
      name
      slug
      purpose
      status
      rejectionReason
      insertedAt
    }
  }
`;

export const LIST_TOOL_CALL_LOGS: TypedDocumentNode<
	{ listToolCallLogs: AdminToolCallLog[] },
	{ workspaceId?: string | null; first?: number; after?: string } & AdminListArgs
> = gql`
  query ListToolCallLogs($workspaceId: ID, $first: Int, $after: String) {
    listToolCallLogs(workspaceId: $workspaceId, first: $first, after: $after) {
      id
      userId
      tool
      resultStatus
      errorMessage
      latencyMs
      insertedAt
    }
  }
`;

export const LIST_PENDING_OPERATIONS: TypedDocumentNode<
	{ listPendingOperations: AdminPendingOperation[] },
	{ workspaceId?: string | null; first?: number; after?: string } & AdminListArgs
> = gql`
  query ListPendingOperations($workspaceId: ID, $first: Int, $after: String) {
    listPendingOperations(workspaceId: $workspaceId, first: $first, after: $after) {
      id
      userId
      tool
      summary
      status
      insertedAt
    }
  }
`;

export const LIST_SIGNAL_LOGS: TypedDocumentNode<
	{ listSignalLogs: AdminSignalLog[] },
	{ workspaceId?: string | null; first?: number; after?: string } & AdminListArgs
> = gql`
  query ListSignalLogs($workspaceId: ID, $first: Int, $after: String) {
    listSignalLogs(workspaceId: $workspaceId, first: $first, after: $after) {
      id
      workspaceId
      signalType
      insertedAt
    }
  }
`;

/** approveWorkspaceApplication 的 result 子集（审批后状态） */
export interface ApproveApplicationResultData {
	result: { id: string; status: AdminApplicationStatus } | null;
	errors: MutationError[];
}

export const APPROVE_WORKSPACE_APPLICATION: TypedDocumentNode<
	{ approveWorkspaceApplication: ApproveApplicationResultData },
	{ id: string }
> = gql`
  mutation ApproveWorkspaceApplication($id: ID!) {
    approveWorkspaceApplication(id: $id) {
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

export interface RejectApplicationResultData {
	result: {
		id: string;
		status: AdminApplicationStatus;
		rejectionReason?: string | null;
	} | null;
	errors: MutationError[];
}

export const REJECT_WORKSPACE_APPLICATION: TypedDocumentNode<
	{ rejectWorkspaceApplication: RejectApplicationResultData },
	{ id: string; input: { rejectionReason?: string | null } }
> = gql`
  mutation RejectWorkspaceApplication($id: ID!, $input: RejectWorkspaceApplicationInput) {
    rejectWorkspaceApplication(id: $id, input: $input) {
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

/** 申请创建工作台（R6 /apply 表单；applicant 自动取当前用户） */
export interface CreateWorkspaceApplicationInput {
	name: string;
	slug: string;
	purpose: string;
}

export interface CreateWorkspaceApplicationResultData {
	result: AdminWorkspaceApplication | null;
	errors: MutationError[];
}

export const CREATE_WORKSPACE_APPLICATION: TypedDocumentNode<
	{ createWorkspaceApplication: CreateWorkspaceApplicationResultData },
	{ input: CreateWorkspaceApplicationInput }
> = gql`
  mutation CreateWorkspaceApplication($input: CreateWorkspaceApplicationInput!) {
    createWorkspaceApplication(input: $input) {
      result {
        id
        applicantId
        name
        slug
        purpose
        status
        rejectionReason
        insertedAt
      }
      errors {
        message
        code
      }
    }
  }
`;

export const PROMOTE_USER: TypedDocumentNode<
	{ promoteUser: AdminUserPayload | null },
	{ id: string }
> = gql`
  mutation PromoteUser($id: ID!) {
    promoteUser(id: $id) {
      id
      email
      isPlatformAdmin
      errors {
        message
        code
      }
    }
  }
`;

export const DEMOTE_USER: TypedDocumentNode<
	{ demoteUser: AdminUserPayload | null },
	{ id: string }
> = gql`
  mutation DemoteUser($id: ID!) {
    demoteUser(id: $id) {
      id
      email
      isPlatformAdmin
      errors {
        message
        code
      }
    }
  }
`;

/* ---------------- 展示辅助 ---------------- */

export const APPLICATION_STATUS_LABEL: Record<AdminApplicationStatus, string> = {
	pending: "待审批",
	approved: "已通过",
	rejected: "已拒绝",
	expired: "已过期",
};

export const APPLICATION_STATUS_CLASS: Record<AdminApplicationStatus, string> = {
	pending: "l-badge l-badge-pending",
	approved: "l-badge l-badge-success",
	rejected: "l-badge l-badge-danger",
	expired: "l-badge l-badge-muted",
};
