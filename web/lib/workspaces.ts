import type { JoinPolicy, MembershipRoleName } from "./graphql/workspace";
import {
  canAssignRoles,
  ROLE_LABEL_ZH,
  WORKSPACE_MEMBERS,
  ME_WORKSPACES,
  ASSIGN_ROLES,
  type WorkspaceMemberConnection,
  type WorkspaceMembership,
  type WorkspaceMembershipRole,
} from "./graphql/workspace";
import { client } from "./apollo-client";

/**
 * #63/#65 工作台与成员角色数据源。
 *
 * 后端 #62 已完成（getWorkspace/getWorkspaceById/createWorkspace 真实可用）；
 * #64 后端已定稿 meWorkspaces + assignRoles（本地 schema 已含，未 push）。
 * Leader 拍板：#63/#65 以 UI/交互/路由为主，mock 先行，后端 #64 完成后切真实数据。
 *
 * 当前：mock 数据（USE_MOCK_WORKSPACES = true）。
 * 切换真实数据：改 USE_MOCK_WORKSPACES = false，并实现 fetchMyWorkspaces() /
 * fetchWorkspaceMembers() / assignMemberRoles() 内的真实 GraphQL 调用，
 * 调用方（app/page.tsx、app/w/[slug]/members/page.tsx）不需要改。
 */

export interface WorkspaceListItem {
  id: string;
  slug: string;
  name: string;
  joinPolicy: JoinPolicy;
  sponsorshipEnabled: boolean;
  /** 当前用户在该工作台的角色名数组（#64 meWorkspaces 的 myRoleNames） */
  myRoleNames?: MembershipRoleName[];
  /** 展示附加字段（mock；真实 meWorkspaces 返回后由后端补齐语义） */
  description?: string;
  memberCount?: number;
  unreadCount?: number;
  roles?: string[];
  membershipStatus?: "active" | "pending" | "invited";
}

/** 成员条目（#65 成员列表 + 角色分配） */
export interface WorkspaceMember {
  /** WorkspaceMembership ID（assignRoles 的 id 参数） */
  membershipId: string;
  /** 全局用户 ID */
  userId: string;
  /** 邮箱（真实 workspaceMembers 返回可能不含 email，前端以 userId 兜底展示） */
  email?: string;
  /** 展示名（mock 附加；真实数据暂无） */
  displayName?: string;
  /** 角色并集（同一成员可持多 role；与后端 multitenancy 多角色并集语义一致） */
  roles: MembershipRoleName[];
}

export const USE_MOCK_WORKSPACES = true;

/** mock：贴合后端 Workspace 真实字段（slug/name/joinPolicy/sponsorshipEnabled + #64 myRoleNames） */
export const MOCK_WORKSPACES: WorkspaceListItem[] = [
  {
    id: "ws_01",
    slug: "cgc-shanghai",
    name: "CGC 上海分社",
    joinPolicy: "open",
    sponsorshipEnabled: true,
    description: "上海线下活动 + 线上学院课程，面向全平台开放加入。",
    memberCount: 128,
    unreadCount: 3,
    myRoleNames: ["member"],
    roles: ["member"],
    membershipStatus: "active",
  },
  {
    id: "ws_02",
    slug: "cgc-academy",
    name: "CGC 线上学院",
    joinPolicy: "request",
    sponsorshipEnabled: true,
    description: "系统化编程课程与教研中心，需申请审批后加入。",
    memberCount: 342,
    unreadCount: 0,
    myRoleNames: ["admin"],
    roles: ["admin"],
    membershipStatus: "active",
  },
  {
    id: "ws_03",
    slug: "cgc-sponsor-hub",
    name: "赞助商俱乐部",
    joinPolicy: "invite_only",
    sponsorshipEnabled: false,
    description: "核心赞助商私密空间，仅凭邀请加入。",
    memberCount: 24,
    unreadCount: 0,
    myRoleNames: [],
    roles: [],
    membershipStatus: "invited",
  },
];

/**
 * mock 成员数据：按 workspaceId 组织。
 * 角色并集演示：同一成员持有多个角色（owner+admin、admin+member 等）。
 */
export const MOCK_MEMBERS: Record<string, WorkspaceMember[]> = {
  ws_01: [
    { membershipId: "wm_0101", userId: "u_0101", email: "xiaomei@example.com", displayName: "小美", roles: ["owner"] },
    { membershipId: "wm_0102", userId: "u_0102", email: "cheng@example.com", displayName: "阿成", roles: ["admin", "member"] },
    { membershipId: "wm_0103", userId: "u_0103", email: "lucy@example.com", displayName: "Lucy", roles: ["member"] },
    { membershipId: "wm_0104", userId: "u_0104", email: "frank@example.com", displayName: "Frank", roles: ["member"] },
  ],
  ws_02: [
    { membershipId: "wm_0201", userId: "u_0201", email: "fangbo@example.com", displayName: "方伯", roles: ["owner"] },
    { membershipId: "wm_0202", userId: "u_0202", email: "xiaomei@example.com", displayName: "小美", roles: ["admin", "member"] },
    { membershipId: "wm_0203", userId: "u_0203", email: "lucy@example.com", displayName: "Lucy", roles: ["member"] },
    { membershipId: "wm_0204", userId: "u_0204", email: "cheng@example.com", displayName: "阿成", roles: ["member"] },
  ],
  ws_03: [
    { membershipId: "wm_0301", userId: "u_0301", email: "sponsor-a@example.com", displayName: "赞助商 A", roles: ["member"] },
    { membershipId: "wm_0302", userId: "u_0302", email: "sponsor-b@example.com", displayName: "赞助商 B", roles: ["member"] },
  ],
};

/**
 * 将后端 workspaceMembers 返回的 roles { id name } 对象数组映射为角色名并集。
 * 未知角色名（如 teacher）会被过滤，仅保留 owner/admin/member。
 */
export function mapRoleObjectsToNames(
  roles: WorkspaceMembershipRole[] | null | undefined,
): MembershipRoleName[] {
  if (!roles) return [];
  const valid: MembershipRoleName[] = ["owner", "admin", "member"];
  return roles
    .map((r) => r.name as MembershipRoleName)
    .filter((n) => valid.includes(n));
}

/**
 * 将后端 workspaceMembers 分页对象（count/results）映射为前端成员列表。
 * 后端返回不含 email 时以 userId 兜底展示。
 */
export function mapWorkspaceMembers(
  conn: WorkspaceMemberConnection | null | undefined,
): WorkspaceMember[] {
  if (!conn || !Array.isArray(conn.results)) return [];
  return conn.results.map((m: WorkspaceMembership) => ({
    membershipId: m.id,
    userId: m.userId,
    email: m.userId,
    displayName: undefined,
    roles: mapRoleObjectsToNames(m.roles),
  }));
}

/**
 * 获取当前用户可进入的 Workspace 列表。
 *
 * 后端 #64 meWorkspaces 已定稿（含 myRoleNames/myMembershipId/canAccess）。
 * USE_MOCK_WORKSPACES=false 时走真实 GraphQL query（需登录，Bearer token 自动附加）。
 */
export async function fetchMyWorkspaces(): Promise<WorkspaceListItem[]> {
  if (USE_MOCK_WORKSPACES) {
    return Promise.resolve(MOCK_WORKSPACES);
  }
  const { data } = await client.query({ query: ME_WORKSPACES });
  return (data?.meWorkspaces ?? []).map((ws) => ({
    id: ws.id,
    slug: ws.slug,
    name: ws.name,
    joinPolicy: ws.joinPolicy,
    sponsorshipEnabled: ws.sponsorshipEnabled,
    myRoleNames: ws.myRoleNames ?? [],
    roles: ws.myRoleNames ?? [],
  }));
}

/**
 * 获取某 workspace 的成员列表（#65）。
 *
 * 后端 #64 workspaceMembers 已定稿（分页对象 count/results + roles{id,name}，
 * filter 用 { workspaceId: { eq } } 内层包装）。USE_MOCK_WORKSPACES=false 时走真实 query。
 */
export async function fetchWorkspaceMembers(
  workspaceId: string,
): Promise<WorkspaceMember[]> {
  if (USE_MOCK_WORKSPACES) {
    return Promise.resolve(MOCK_MEMBERS[workspaceId] ?? []);
  }
  const { data } = await client.query({
    query: WORKSPACE_MEMBERS,
    variables: { filter: { workspaceId: { eq: workspaceId } } },
  });
  return mapWorkspaceMembers(data?.workspaceMembers);
}

/**
 * 分配成员角色（多角色并集，替换整组；仅 Owner/Admin 应调用）。
 * mock：内存更新 MOCK_MEMBERS 中对应成员的 roles。
 * 真实：调用后端 assignRoles mutation（id = membershipId，roleNames 替换整组，
 * 空数组 = 清空角色；非 Owner/Admin 后端返回 forbidden error）。
 */
export async function assignMemberRoles(
  workspaceId: string,
  membershipId: string,
  roleNames: MembershipRoleName[],
): Promise<WorkspaceMember> {
  if (USE_MOCK_WORKSPACES) {
    const members = MOCK_MEMBERS[workspaceId] ?? [];
    const idx = members.findIndex((m) => m.membershipId === membershipId);
    if (idx === -1) {
      throw new Error(`member not found: ${membershipId}`);
    }
    const updated: WorkspaceMember = { ...members[idx], roles: [...roleNames] };
    members[idx] = updated;
    return Promise.resolve(updated);
  }
  const { data } = await client.mutate({
    mutation: ASSIGN_ROLES,
    variables: { id: membershipId, input: { roleNames } },
  });
  const result = data?.assignRoles?.result;
  if (!result) {
    const msg = data?.assignRoles?.errors?.[0]?.message ?? "assignRoles failed";
    throw new Error(msg);
  }  return {
    membershipId: result.id,
    userId: result.userId,
    email: result.userId,
    displayName: undefined,
    roles: mapRoleObjectsToNames(result.roles),
  };
}

/**
 * 当前用户是否可在某 workspace 内分配角色（Owner/Admin）。
 * 从 workspace 的 myRoleNames（当前用户角色并集）判断。
 * ws 可能为 undefined（未知 slug / 未匹配），此时不可分配。
 */
export function currentUserCanAssignRoles(ws: WorkspaceListItem | undefined): boolean {
  return canAssignRoles(ws?.myRoleNames);
}

/** 角色并集的中文展示（成员卡片徽章文案） */
export function roleLabelsZh(roles: MembershipRoleName[]): string[] {
  return roles.map((r) => ROLE_LABEL_ZH[r] ?? r);
}
