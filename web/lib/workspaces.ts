import type { JoinPolicy, MembershipRoleName, Workspace } from "./graphql/workspace";
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
 * #64 已定稿 meWorkspaces + assignRoles；#66 已定稿 permissionMatrix/myAbilities；
 * #68 已定稿 me/updateProfile。
 *
 * 当前：真实数据（USE_MOCK_WORKSPACES = false），所有 fetch 与 assign 函数走 GraphQL。
 * 保留 mock 数据作兜底：本地无后端联调时可切 USE_MOCK_WORKSPACES = true 回到 mock。
 * 调用方（app/page.tsx、app/w/[slug]/members/page.tsx、app/profile/page.tsx）不需要改。
 */

export interface WorkspaceListItem {
  id: string;
  slug: string;
  name: string;
  joinPolicy: JoinPolicy;
  sponsorshipEnabled: boolean;
  /** 当前用户在该工作台的角色名数组（#64 meWorkspaces 的 myRoleNames） */
  myRoleNames?: MembershipRoleName[];
  /** 当前用户在该工作台的成员资格 ID（#64 meWorkspaces 的 myMembershipId；非成员为 null） */
  myMembershipId?: string | null;
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
  /** 加入时间（设计稿展示字段；真实 GraphQL 未返回时由页面显示 —） */
  joinedAt?: string;
  /** 角色并集（同一成员可持多 role；与后端 multitenancy 多角色并集语义一致） */
  roles: MembershipRoleName[];
}

export const USE_MOCK_WORKSPACES = false;

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
 * 角色并集演示：同一成员持有多个角色（Owner+Tutor、Tutor+Volunteer 等）。
 */
export const MOCK_MEMBERS: Record<string, WorkspaceMember[]> = {
  ws_01: [
    { membershipId: "wm_0101", userId: "u_0101", email: "xiaomei@example.com", displayName: "小美", joinedAt: "2024-03-12", roles: ["owner"] },
    { membershipId: "wm_0102", userId: "u_0102", email: "cheng@example.com", displayName: "阿成", joinedAt: "2024-04-08", roles: ["admin", "member"] },
    { membershipId: "wm_0103", userId: "u_0103", email: "lucy@example.com", displayName: "Lucy", joinedAt: "2025-01-16", roles: ["member"] },
    { membershipId: "wm_0104", userId: "u_0104", email: "frank@example.com", displayName: "Frank", joinedAt: "2025-05-21", roles: ["member"] },
  ],
  ws_02: [
    { membershipId: "wm_0201", userId: "u_0201", email: "linxi@cgc2046.org", displayName: "林溪", joinedAt: "2024-03-12", roles: ["owner", "tutor"] },
    { membershipId: "wm_0202", userId: "u_0202", email: "chenyu@cgc2046.org", displayName: "陈雨", joinedAt: "2024-04-08", roles: ["admin"] },
    { membershipId: "wm_0203", userId: "u_0203", email: "zhouning@cgc2046.org", displayName: "周宁", joinedAt: "2025-01-16", roles: ["tutor", "volunteer"] },
    { membershipId: "wm_0204", userId: "u_0204", email: "suman@cgc2046.org", displayName: "苏曼", joinedAt: "2025-05-21", roles: ["volunteer"] },
    { membershipId: "wm_0205", userId: "u_0205", email: "hemiao@cgc2046.org", displayName: "何苗", joinedAt: "2026-07-30", roles: ["learner"] },
  ],
  ws_03: [
    { membershipId: "wm_0301", userId: "u_0301", email: "sponsor-a@example.com", displayName: "赞助商 A", joinedAt: "2026-06-09", roles: ["member"] },
    { membershipId: "wm_0302", userId: "u_0302", email: "sponsor-b@example.com", displayName: "赞助商 B", joinedAt: "2026-06-18", roles: ["member"] },
  ],
};

/**
 * 将后端 workspaceMembers 返回的 roles { id name } 对象数组映射为角色名并集。
 * 未知角色名（如 teacher）会被过滤；内置角色与旧 member 均保留。
 */
export function mapRoleObjectsToNames(
  roles: WorkspaceMembershipRole[] | null | undefined,
): MembershipRoleName[] {
  if (!roles) return [];
  const valid: MembershipRoleName[] = [
    "owner",
    "admin",
    "tutor",
    "volunteer",
    "learner",
    "member",
  ];
  return roles
    .map((r) => r.name as MembershipRoleName)
    .filter((n) => valid.includes(n));
}

/**
 * 将后端 workspaceMembers 分页对象（count/results）映射为前端成员列表。
 * P1：平铺字段 userEmail/userDisplayName/joinedAt 直接映射
 * （不再嵌套 user{}；后端 G6 偏离说明——User read policy 只允许本人读自己，
 * 嵌套关系会被过滤为 null，故用 SQL LEFT JOIN 平铺字段）。
 * 后端未返回时以 userId 兜底展示。
 */
export function mapWorkspaceMembers(
  conn: WorkspaceMemberConnection | null | undefined,
): WorkspaceMember[] {
  if (!conn || !Array.isArray(conn.results)) return [];
  return conn.results.map((m: WorkspaceMembership) => ({
    membershipId: m.id,
    userId: m.userId,
    email: m.userEmail ?? m.userId,
    displayName: m.userDisplayName ?? undefined,
    joinedAt: m.joinedAt ?? undefined,
    roles: mapRoleObjectsToNames(m.roles),
  }));
}

/**
 * 将后端 meWorkspaces 的 Workspace 映射为前端 membershipStatus（#70 QA P2）。
 *
 * 对齐后端契约字段：
 * - canAccess === true 或持有角色（myRoleNames 非空）→ "active"（已加入，可进入）；
 * - 有成员资格（myMembershipId）但暂不可访问 → "pending"（申请审批中）；
 * - 仅受邀（无资格、无角色、不可访问）→ "invited"（待凭据加入）。
 * 真实 meWorkspaces 语义为「当前用户可进入的工作台列表」，正常返回均为 active；
 * 映射函数兼容后续后端扩展（邀请/待审批状态）。
 */
export function mapMembershipStatus(
  ws: Pick<Workspace, "canAccess" | "myMembershipId" | "myRoleNames"> | null | undefined,
): WorkspaceListItem["membershipStatus"] {
  if (!ws) return "invited";
  if (ws.canAccess === true || (ws.myRoleNames?.length ?? 0) > 0) return "active";
  if (ws.myMembershipId) return "pending";
  return "invited";
}

/**
 * 获取当前用户可进入的 Workspace 列表。
 *
 * 后端 #64 meWorkspaces 已定稿（含 myRoleNames/myMembershipId/canAccess）。
 * USE_MOCK_WORKSPACES=false 时走真实 GraphQL query（需登录，Bearer token 自动附加），
 * 并补齐 membershipStatus（#70 QA P2：恢复已加入/待处理统计与进入入口）。
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
    membershipStatus: mapMembershipStatus(ws),
    myMembershipId: ws.myMembershipId ?? null,
    memberCount: ws.memberCount ?? undefined,
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
  }
  return mapAssignRolesResult(result);
}

/**
 * 将后端 assignRoles 返回的 WorkspaceMembership 映射为前端成员条目。
 * #65 review 修复：selection 含 roles{id,name}，保存后回填非空（不再显示 []）。
 * P1：平铺 userEmail/userDisplayName/joinedAt 若返回则透传。
 */
export function mapAssignRolesResult(
  result: WorkspaceMembership,
): WorkspaceMember {
  return {
    membershipId: result.id,
    userId: result.userId,
    email: result.userEmail ?? result.userId,
    displayName: result.userDisplayName ?? undefined,
    joinedAt: result.joinedAt ?? undefined,
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
