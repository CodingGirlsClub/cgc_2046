import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

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
 * 管理角色子集（可管理成员/角色分配）前端唯一真源。
 *
 * 后端单源是 `Role.manage_roles/0`，经契约工件 rbac_contract.json 的
 * manage_roles 字段下发；permissions.contract.test.ts 断言本常量与工件
 * 双向一致 —— 后端调整子集后未同步此处 = CI 红灯。
 * 其它文件一律 import 本常量 / GRANTABLE_ROLE_NAMES，不得重申 owner/admin 子集。
 */
export const MANAGE_ROLE_NAMES: MembershipRoleName[] = ["owner", "admin"];

/**
 * 可授予角色子集（邀请预授权 / 加入审批可选角色）= ROLE_NAMES − 管理角色。
 * 管理级角色（owner/admin）不可经邀请/审批授予，Owner 走专门指派。
 */
export const GRANTABLE_ROLE_NAMES: MembershipRoleName[] = ROLE_NAMES.filter(
	(role) => !MANAGE_ROLE_NAMES.includes(role),
);

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
	/** 赞助档位配置（JsonString 数组，每项 JSON.parse 后为 SponsorshipTierConfig；E-3 #48） */
	sponsorshipTiers?: string[] | null;
	/** 当前用户在该工作台的角色名数组（非成员为 []）— #64 */
	myRoleNames?: MembershipRoleName[];
	/** 当前用户在该工作台的成员资格 ID（非成员为 null）— #64 */
	myMembershipId?: string | null;
	/** 当前用户是否可进入该工作台（成员/创建者）— #64 */
	canAccess?: boolean;
	/** 当前用户在该工作台的能力列表（#1 能力接口：随 meWorkspaces 下发，由后端 Rbac.abilities_for/2 单源派生） */
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

export interface CreateWorkspaceInput {
	slug: string;
	name: string;
	joinPolicy?: JoinPolicy;
	sponsorshipEnabled?: boolean;
	/** 指定已有用户为 Owner（Phase 4：替代 actor.id 建 Owner membership） */
	ownerUserId?: string;
	/** 邀请新用户为 Owner（创建 preauthorized [:owner] 的 Invitation，pending-owner） */
	ownerEmail?: string;
}

/** createWorkspace 的 metadata：pending-owner 邀请明文 token（仅创建时返回一次） */
export interface CreateWorkspaceMetadata {
	ownerInvitationToken?: string | null;
}

export type CreateWorkspaceResultData = MutationResult<Workspace> & {
	metadata?: CreateWorkspaceMetadata | null;
};

export interface ReassignWorkspaceOwnerInput {
	/** 改指现有用户为 Owner（建 Owner membership）；与 ownerEmail 二选一 */
	ownerUserId?: string;
	/** 改发 pending-owner 邀请给新邮箱（preauthorized [:owner]，带 expires_at）；与 ownerUserId 二选一 */
	ownerEmail?: string;
}

/** reassignWorkspaceOwner 的 metadata：新 pending-owner 邀请明文 token（仅返回一次，不落库） */
export interface ReassignWorkspaceOwnerMetadata {
	ownerInvitationToken?: string | null;
}

export type ReassignWorkspaceOwnerResultData = MutationResult<Workspace> & {
	metadata?: ReassignWorkspaceOwnerMetadata | null;
};

export interface UpdateWorkspaceInput {
	slug?: string;
	name?: string;
	joinPolicy?: JoinPolicy;
	sponsorshipEnabled?: boolean;
	/** 赞助档位配置（每项 JSON.stringify 后作为 JsonString 提交；E-3 #48） */
	sponsorshipTiers?: string[];
}

export type UpdateWorkspaceResultData = MutationResult<Workspace>;

export interface AssignRolesInput {
	/** 角色名数组（多角色并集，替换整组）；空数组 = 清空角色 */
	roleNames: MembershipRoleName[];
}

export type AssignRolesResultData = MutationResult<WorkspaceMembership>;

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
      sponsorshipTiers
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
      metadata {
        ownerInvitationToken
      }
      errors {
        message
        code
      }
    }
  }
`;

/**
 * #114 reassignWorkspaceOwner：重指派 pending-owner 工作台的 Owner（仅平台管理员，
 * 工作台已有 Owner 时后端报错）。原子撤销当前 active Owner 邀请 +
 * ownerUserId 改指现有用户直接入座 / ownerEmail 改发新 pending-owner 邀请
 * （7 天有效期，明文 token 经 metadata 仅返回一次）。
 */
export const REASSIGN_WORKSPACE_OWNER: TypedDocumentNode<
	{ reassignWorkspaceOwner: ReassignWorkspaceOwnerResultData },
	{ id: string; input: ReassignWorkspaceOwnerInput }
> = gql`
  mutation ReassignWorkspaceOwner($id: ID!, $input: ReassignWorkspaceOwnerInput!) {
    reassignWorkspaceOwner(id: $id, input: $input) {
      result {
        id
        slug
        name
        joinPolicy
        sponsorshipEnabled
      }
      metadata {
        ownerInvitationToken
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
        sponsorshipTiers
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
