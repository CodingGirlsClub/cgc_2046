import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #63/#65 Workspace GraphQL 契约（对齐后端 #62 schema commit af974b5 + #64 membership）。
 *
 * 关键约定（与后端工程师 worker_c5ca4e44 确认）：
 * - Workspace type：{ id, slug, name, joinPolicy, sponsorshipEnabled }
 * - getWorkspace(slug) / getWorkspaceById(id)：需登录（Bearer token），返回单个 Workspace。
 * - #64 新增：meWorkspaces 查询（当前用户可进入的工作台列表，成员资格+创建者），
 *   Workspace 上带 myRoleNames / myMembershipId / canAccess 计算字段。
 * - #64 新增：assignRoles(id, input{roleNames}) 分配成员角色（多角色并集，仅 Owner/Admin），
 *   id 为 WorkspaceMembership ID；result 返回 WorkspaceMembership。
 * - createWorkspace(input)：仅平台管理员可调，返回 CreateWorkspaceResult { result, errors }。
 */

/* ---------------- 类型（对齐 backend/priv/graphql/schema.graphql） ---------------- */

export type JoinPolicy = "open" | "request" | "invite_only";

/**
 * 六角色枚举唯一真源（Shotgun Surgery 修复，2026-08-02）。
 *
 * 加第 7 个角色只改这里；其它文件一律 import ROLE_NAMES / MembershipRoleName，
 * 不得重复六角色完整字面量数组。
 */
export const ROLE_NAMES = [
	"owner",
	"admin",
	"tutor",
	"volunteer",
	"learner",
	"member",
] as const;

/**
 * 成员角色名（由 ROLE_NAMES 派生，保证与单源一致）。
 *
 * #64 的早期 API 只 seed 了 owner/admin/member；Slice A 的正式领域设计
 * 将 Role 定义为 Workspace 内可扩展实体，并约定默认模板为
 * Owner/Admin/Tutor/Volunteer/Learner。前端因此同时识别两套名称：旧的
 * member 仍可兼容读取，设计稿中的四个非 Owner 角色可直接展示与编辑。
 */
export type MembershipRoleName = (typeof ROLE_NAMES)[number];

export interface Workspace {
	id: string;
	/** 工作台唯一标识（小写字母/数字/连字符，创建者提供） */
	slug: string;
	/** 工作台名称 */
	name: string;
	/** 加入策略：open 公开直接加入 / request 公开申请审批 / invite_only 私密仅邀请 */
	joinPolicy: JoinPolicy;
	/** 是否开放赞助入口（默认开） */
	sponsorshipEnabled: boolean;
	/** 当前用户在该工作台的角色名数组（非成员为 []）— #64 */
	myRoleNames?: MembershipRoleName[];
	/** 当前用户在该工作台的成员资格 ID（非成员为 null）— #64 */
	myMembershipId?: string | null;
	/** 当前用户是否可进入该工作台（成员/创建者）— #64 */
	canAccess?: boolean;
	/** 当前用户在该工作台的能力列表（#1 能力接口：随 meWorkspaces 下发，语义与后端 Rbac.abilities/2 一致） */
	myAbilities?: string[];
	/** 成员数量（P1 计算字段，SQL count(memberships)） */
	memberCount?: number | null;
}

export interface WorkspaceMembership {
	id: string;
	/** 所属工作台（租户）ID */
	workspaceId: string;
	/** 成员（全局用户）ID */
	userId: string;
	/** 角色并集（#64 补充：workspaceMembers 返回 roles { id name } 对象数组） */
	roles?: WorkspaceMembershipRole[] | null;
	/** 成员邮箱（P1 平铺计算字段，SQL LEFT JOIN users，不经 User read policy） */
	userEmail?: string | null;
	/** 成员昵称（P1 平铺计算字段） */
	userDisplayName?: string | null;
	/** 加入时间（P1 平铺计算字段，= inserted_at） */
	joinedAt?: string | null;
}

/** 成员角色对象（#64 workspaceMembers 的 roles 字段返回结构） */
export interface WorkspaceMembershipRole {
	id: string;
	name: string;
}

/** workspaceMembers 分页对象（后端返回 count/results + 游标） */
export interface WorkspaceMemberConnection {
	count: number;
	results: WorkspaceMembership[];
	startKeyset?: string | null;
	endKeyset?: string | null;
}

/**
 * workspaceMembers filter：workspaceId 用 eq 比较器内层包装；
 * 支持后端下推搜索（userEmail/userDisplayName ilike，大小写不敏感）与角色过滤（roles.name eq）。
 */
export interface WorkspaceMembersFilter {
	workspaceId?: { eq?: string } | null;
	userEmail?: { ilike?: string } | null;
	userDisplayName?: { ilike?: string } | null;
	roles?: { name?: { eq?: string } | null } | null;
	and?: WorkspaceMembersFilter[] | null;
	or?: WorkspaceMembersFilter[] | null;
}

export interface MutationError {
	message?: string | null;
	code?: string | null;
}

export interface CreateWorkspaceInput {
	slug: string;
	name: string;
	joinPolicy?: JoinPolicy;
	sponsorshipEnabled?: boolean;
}

export interface CreateWorkspaceResultData {
	result: Workspace | null;
	errors: MutationError[];
}

export interface UpdateWorkspaceInput {
	slug?: string;
	name?: string;
	joinPolicy?: JoinPolicy;
	sponsorshipEnabled?: boolean;
}

export interface UpdateWorkspaceResultData {
	result: Workspace | null;
	errors: MutationError[];
}

export interface AssignRolesInput {
	/** 角色名数组（多角色并集，替换整组）；空数组 = 清空角色 */
	roleNames: MembershipRoleName[];
}

export interface AssignRolesResultData {
	result: WorkspaceMembership | null;
	errors: MutationError[];
}

/* ---------------- 真实 query / mutation ---------------- */

/** #64 meWorkspaces：当前用户可进入的工作台列表（成员资格 + 创建者；P1 带 memberCount；#1 带 myAbilities） */
export const ME_WORKSPACES: TypedDocumentNode<
	{ meWorkspaces: Workspace[] },
	Record<string, never>
> = gql`
  query MeWorkspaces {
    meWorkspaces {
      id
      slug
      name
      joinPolicy
      sponsorshipEnabled
      myRoleNames
      myMembershipId
      canAccess
      myAbilities
      memberCount
    }
  }
`;

/**
 * #64 assignRoles：分配成员角色（多角色并集，仅 Owner/Admin）。
 * id 为 WorkspaceMembership ID。
 */
export const ASSIGN_ROLES: TypedDocumentNode<
	{ assignRoles: AssignRolesResultData },
	{ id: string; input: AssignRolesInput }
> = gql`
  mutation AssignRoles($id: ID!, $input: AssignRolesInput!) {
    assignRoles(id: $id, input: $input) {
      result {
        id
        workspaceId
        userId
        roles {
          id
          name
        }
      }
      errors {
        message
        code
      }
    }
  }
`;

/**
 * #64 workspaceMembers：成员列表查询（分页对象，filter 用 eq 比较器包装 workspaceId）。
 * 单成员多角色通过 roles { id name } 并集返回。
 * P1：平铺计算字段 userEmail/userDisplayName/joinedAt（不再嵌套 user，规避 User read policy 过滤）。
 * #10：支持 keyset 分页（first/after）与后端下推搜索/角色过滤。
 */
export const WORKSPACE_MEMBERS: TypedDocumentNode<
	{ workspaceMembers: WorkspaceMemberConnection },
	{ filter: WorkspaceMembersFilter; first?: number; after?: string }
> = gql`
  query WorkspaceMembers($filter: WorkspaceMembershipFilterInput!, $first: Int, $after: String) {
    workspaceMembers(filter: $filter, first: $first, after: $after) {
      count
      results {
        id
        workspaceId
        userId
        userEmail
        userDisplayName
        joinedAt
        roles {
          id
          name
        }
      }
      startKeyset
      endKeyset
    }
  }
`;

export const GET_WORKSPACE: TypedDocumentNode<
	{ getWorkspace: Workspace | null },
	{ slug: string }
> = gql`
  query GetWorkspace($slug: String!) {
    getWorkspace(slug: $slug) {
      id
      slug
      name
      joinPolicy
      sponsorshipEnabled
    }
  }
`;

export const GET_WORKSPACE_BY_ID: TypedDocumentNode<
	{ getWorkspaceById: Workspace | null },
	{ id: string }
> = gql`
  query GetWorkspaceById($id: ID!) {
    getWorkspaceById(id: $id) {
      id
      slug
      name
      joinPolicy
      sponsorshipEnabled
    }
  }
`;

export const CREATE_WORKSPACE: TypedDocumentNode<
	{ createWorkspace: CreateWorkspaceResultData },
	{ input: CreateWorkspaceInput }
> = gql`
  mutation CreateWorkspace($input: CreateWorkspaceInput!) {
    createWorkspace(input: $input) {
      result {
        id
        slug
        name
        joinPolicy
        sponsorshipEnabled
      }
      errors {
        message
        code
      }
    }
  }
`;

/**
 * #78 updateWorkspace：更新工作台（Owner/Admin 或平台管理员）。
 * 设置页仅用 joinPolicy 字段（最小范围）；accept 已含 slug/name/sponsorshipEnabled。
 */
export const UPDATE_WORKSPACE: TypedDocumentNode<
	{ updateWorkspace: UpdateWorkspaceResultData },
	{ id: string; input: UpdateWorkspaceInput }
> = gql`
  mutation UpdateWorkspace($id: ID!, $input: UpdateWorkspaceInput!) {
    updateWorkspace(id: $id, input: $input) {
      result {
        id
        slug
        name
        joinPolicy
        sponsorshipEnabled
      }
      errors {
        message
        code
      }
    }
  }
`;

/* ---------------- join_policy 展示辅助 ---------------- */

export const JOIN_POLICY_LABEL: Record<JoinPolicy, string> = {
	open: "公开",
	request: "申请审批",
	invite_only: "仅邀请",
};

export const JOIN_POLICY_HINT: Record<JoinPolicy, string> = {
	open: "公开直接加入",
	request: "公开申请审批",
	invite_only: "私密仅邀请",
};

/* ---------------- 成员角色（#64）展示辅助 ---------------- */

/** 成员角色全集（引用 ROLE_NAMES 单源，与共享 ROLE_LABEL 六角色一致） */
export const MEMBERSHIP_ROLES: MembershipRoleName[] = [...ROLE_NAMES];

export const ROLE_LABEL: Record<MembershipRoleName, string> = {
	owner: "Owner",
	admin: "Admin",
	tutor: "Tutor",
	volunteer: "Volunteer",
	learner: "Learner",
	member: "Member",
};

export const ROLE_LABEL_ZH: Record<MembershipRoleName, string> = {
	owner: "所有者",
	admin: "管理员",
	tutor: "教练",
	volunteer: "志愿者",
	learner: "学员",
	member: "成员",
};

/** 角色徽章样式（Linear 风格双主题，配合 globals.css 的 l-badge-* 类） */
export const ROLE_BADGE_CLASS: Record<MembershipRoleName, string> = {
	owner: "l-badge l-badge-owner",
	admin: "l-badge l-badge-admin",
	tutor: "l-badge l-badge-tutor",
	volunteer: "l-badge l-badge-volunteer",
	learner: "l-badge l-badge-learner",
	member: "l-badge l-badge-member",
};
