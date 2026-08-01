import type { MembershipRoleName } from "./graphql/workspace";
import { ROLE_LABEL, ROLE_LABEL_ZH, ROLE_BADGE_CLASS } from "./graphql/workspace";
import { PERMISSION_MATRIX, MY_ABILITIES, type RbacAbility, type RbacPermissionMatrixRow } from "./graphql/permissions";
import { client } from "./apollo-client";
import { USE_MOCK_WORKSPACES } from "./workspaces";

/**
 * #67 权限表可视化（角色 → 能力映射）。
 *
 * 切片A 相关资源（Workspace 创建/读取、成员管理、角色分配、invite_only 读取等），
 * 语义对齐后端 #64/#66 Rbac policies：
 * - workspace_membership policy：读取 = 成员本人可读自己 / Owner/Admin 可读全部；
 *   create/destroy/update(assign_roles) = 仅 Owner/Admin（WorkspaceActorIsOwnerOrAdmin，多角色并集）
 * - role policy：读取 = 任何已认证用户（用于展示）
 * - createWorkspace：#62 起仅平台管理员（is_platform_admin）
 *
 * mock 先行；后端 #66 Rbac 已定稿（GraphQL permissionMatrix / myAbilities，commit 2fdf506）。
 * USE_MOCK_WORKSPACES = false 时走真实分支：
 * - fetchPermissionsMatrix() → permissionMatrix（三角色 × 六能力，需登录）
 * - fetchMyAbilities(workspaceId) → myAbilities（当前用户动态能力，需登录）
 * 调用方无需改。
 */

/** 能力 ID（切片A 相关） */
export type PermissionAbility =
  | "view_workspace"
  | "access_invite_only"
  | "list_members"
  | "manage_members"
  | "assign_roles"
  | "create_workspace";

export interface PermissionAbilityDef {
  id: PermissionAbility;
  /** 能力名（表头） */
  label: string;
  /** 能力说明 */
  description: string;
}

export interface PermissionMatrixRow {
  role: MembershipRoleName;
  /** 该角色对每个能力的支持情况 */
  abilities: Record<PermissionAbility, boolean>;
  /** 行尾说明（如平台管理员专属） */
  note?: string;
}

/** 能力列定义（顺序即表头顺序） */
export const PERMISSION_ABILITIES: PermissionAbilityDef[] = [
  {
    id: "view_workspace",
    label: "查看工作台",
    description: "查看工作台详情与基本配置（getWorkspace / meWorkspaces）",
  },
  {
    id: "access_invite_only",
    label: "访问仅邀请工作台",
    description: "invite_only 工作台需受邀成为成员后方可访问",
  },
  {
    id: "list_members",
    label: "查看全部成员",
    description: "查看工作台全部成员列表（普通成员仅见自己）",
  },
  {
    id: "manage_members",
    label: "添加/移除成员",
    description: "创建/删除成员资格（仅 Owner/Admin，对应 create/destroy policy）",
  },
  {
    id: "assign_roles",
    label: "分配成员角色",
    description: "替换成员角色整组（多角色并集，空数组=清空；仅 Owner/Admin）",
  },
  {
    id: "create_workspace",
    label: "创建工作台",
    description: "创建新工作台（#62 起仅平台管理员）",
  },
];

/**
 * 角色 → 能力矩阵（mock，对齐后端 can? 语义）。
 * owner/admin 具有管理类能力（成员管理/角色分配）；member 仅基础访问；
 * create_workspace 为平台管理员专属（三角色均不支持，见 note）。
 */
export const MOCK_PERMISSION_MATRIX: PermissionMatrixRow[] = [
  {
    role: "owner",
    abilities: {
      view_workspace: true,
      access_invite_only: true,
      list_members: true,
      manage_members: true,
      assign_roles: true,
      create_workspace: false,
    },
    note: "工作台所有者，全部管理能力",
  },
  {
    role: "admin",
    abilities: {
      view_workspace: true,
      access_invite_only: true,
      list_members: true,
      manage_members: true,
      assign_roles: true,
      create_workspace: false,
    },
    note: "管理员，与 Owner 相同的成员管理能力",
  },
  {
    role: "member",
    abilities: {
      view_workspace: true,
      access_invite_only: true,
      list_members: false,
      manage_members: false,
      assign_roles: false,
      create_workspace: false,
    },
    note: "普通成员：基础访问，成员列表仅见自己",
  },
];

/** 当前用户某角色是否支持某能力（多角色并集：任一角色支持即支持） */
export function roleHasAbility(
  row: PermissionMatrixRow,
  ability: PermissionAbility,
): boolean {
  return row.abilities[ability] === true;
}

/** 某用户（角色并集）是否支持某能力：并集判定，任一角色支持即支持 */
export function myRolesHaveAbility(
  myRoles: MembershipRoleName[] | null | undefined,
  matrix: PermissionMatrixRow[],
  ability: PermissionAbility,
): boolean {
  if (!myRoles || myRoles.length === 0) return false;
  return myRoles.some((r) => {
    const row = matrix.find((m) => m.role === r);
    return row ? roleHasAbility(row, ability) : false;
  });
}

/**
 * 将后端 #66 permissionMatrix 返回的 roles（name + abilities）映射为前端
 * PermissionMatrixRow 列表。未知角色名（非 owner/admin/member）会被过滤。
 */
export function mapPermissionMatrixRows(
  rows: RbacPermissionMatrixRow[] | null | undefined,
): PermissionMatrixRow[] {
  if (!rows || !Array.isArray(rows)) return [];
  const valid: MembershipRoleName[] = ["owner", "admin", "member"];
  return rows
    .filter(
      (r): r is RbacPermissionMatrixRow & { name: MembershipRoleName } =>
        valid.includes(r.name as MembershipRoleName),
    )
    .map((r) => ({
      role: r.name,
      abilities: {
        view_workspace: r.abilities.view_workspace,
        access_invite_only: r.abilities.access_invite_only,
        list_members: r.abilities.list_members,
        manage_members: r.abilities.manage_members,
        assign_roles: r.abilities.assign_roles,
        create_workspace: r.abilities.create_workspace,
      },
    }));
}

/**
 * 获取权限矩阵（mock 先行；USE_MOCK_WORKSPACES = false 时走 #66 permissionMatrix 真实查询）。
 * 后端返回 abilities 字段名即 snake_case 能力名，与 PermissionAbility 完全对齐。
 */
export async function fetchPermissionsMatrix(): Promise<PermissionMatrixRow[]> {
  if (USE_MOCK_WORKSPACES) {
    return Promise.resolve(MOCK_PERMISSION_MATRIX);
  }
  const { data } = await client.query({ query: PERMISSION_MATRIX });
  return mapPermissionMatrixRows(data?.permissionMatrix?.roles);
}

/**
 * 当前用户在指定工作台的动态能力列表（#66 myAbilities，需登录）。
 * 返回能力名数组（如 ["view_workspace","access_invite_only"]）；匿名/无权限时后端
 * 返回 unauthorized，此处抛错由调用方捕获。
 */
export async function fetchMyAbilities(workspaceId: string): Promise<RbacAbility[]> {
  if (USE_MOCK_WORKSPACES) {
    // mock：基础访问能力（view/access），管理类能力由页面按矩阵+myRoles 推导
    return Promise.resolve(["view_workspace", "access_invite_only"]);
  }
  const { data } = await client.query({ query: MY_ABILITIES, variables: { workspaceId } });
  const abilities = (data?.myAbilities?.abilities ?? []) as RbacAbility[];
  return abilities;
}

/** 角色展示辅助（复用 #65 角色模型） */
export const PERMISSION_ROLE_LABEL = ROLE_LABEL;
export const PERMISSION_ROLE_LABEL_ZH = ROLE_LABEL_ZH;
export const PERMISSION_ROLE_BADGE_CLASS = ROLE_BADGE_CLASS;
