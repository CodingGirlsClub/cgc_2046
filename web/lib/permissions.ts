import type { MembershipRoleName } from "./graphql/workspace";
import { ROLE_BADGE_CLASS, ROLE_LABEL, ROLE_LABEL_ZH } from "./graphql/workspace";
import {
  PERMISSION_MATRIX,
  MY_ABILITIES,
  type RbacAbility,
  type RbacPermissionMatrixRow,
} from "./graphql/permissions";
import { client } from "./apollo-client";
import { USE_MOCK_WORKSPACES } from "./workspaces";

/**
 * #67 权限映射页的数据模型。
 *
 * 设计稿将权限页收敛为 Workspace 内的七项能力，并以五个默认角色展示：
 * Owner / Admin / Tutor / Volunteer / Learner。后端 #66 的早期查询仍返回
 * owner/admin/member + 六项旧能力，因此真实分支在这里做一次兼容映射，避免
 * 页面把旧 GraphQL 字段直接暴露成过时的 UI。
 */

/** 设计稿中的能力 ID。 */
export type PermissionAbility =
  | "view_members"
  | "manage_members"
  | "assign_roles"
  | "change_join_policy"
  | "view_profile"
  | "edit_own_profile"
  | "cross_workspace_access";

export interface PermissionAbilityDef {
  id: PermissionAbility;
  label: string;
  description: string;
}

export interface PermissionMatrixRow {
  role: MembershipRoleName;
  abilities: Record<PermissionAbility, boolean>;
  note?: string;
}

/** 设计稿固定的默认角色顺序；旧 member 只作为兼容输入，不出现在正式矩阵。 */
export const PERMISSION_ROLE_ORDER: MembershipRoleName[] = [
  "owner",
  "admin",
  "tutor",
  "volunteer",
  "learner",
];

export const PERMISSION_ABILITIES: PermissionAbilityDef[] = [
  {
    id: "view_members",
    label: "查看成员",
    description: "查看当前 Workspace 的成员列表与成员角色并集。",
  },
  {
    id: "manage_members",
    label: "管理成员",
    description: "添加、移除或管理当前 Workspace 的成员关系。",
  },
  {
    id: "assign_roles",
    label: "行内分配角色",
    description: "在成员页调整 Owner 之外的角色；Owner 走专门指派流程。",
  },
  {
    id: "change_join_policy",
    label: "修改加入策略",
    description: "修改 open / request / invite_only 等 Workspace 加入策略。",
  },
  {
    id: "view_profile",
    label: "查看租户内 Profile",
    description: "查看当前 Workspace 成员可见的 Profile 信息。",
  },
  {
    id: "edit_own_profile",
    label: "编辑自己的 Profile",
    description: "编辑自己的展示名、简介、技能标签与作品集。",
  },
  {
    id: "cross_workspace_access",
    label: "跨 Workspace 访问",
    description: "跨租户读取或操作其他 Workspace 的资源，默认一律拒绝。",
  },
];

type PermissionAbilities = Record<PermissionAbility, boolean>;

const OWNER_ABILITIES: PermissionAbilities = {
  view_members: true,
  manage_members: true,
  assign_roles: true,
  change_join_policy: true,
  view_profile: true,
  edit_own_profile: true,
  cross_workspace_access: false,
};

const ADMIN_ABILITIES: PermissionAbilities = {
  ...OWNER_ABILITIES,
  change_join_policy: false,
};

const MEMBER_ABILITIES: PermissionAbilities = {
  view_members: true,
  manage_members: false,
  assign_roles: false,
  change_join_policy: false,
  view_profile: true,
  edit_own_profile: true,
  cross_workspace_access: false,
};

const ROLE_DEFAULT_ABILITIES: Record<MembershipRoleName, PermissionAbilities> = {
  owner: OWNER_ABILITIES,
  admin: ADMIN_ABILITIES,
  tutor: MEMBER_ABILITIES,
  volunteer: MEMBER_ABILITIES,
  learner: MEMBER_ABILITIES,
  // 早期 API 的 member 与设计稿 Learner 语义最接近。
  member: MEMBER_ABILITIES,
};

function cloneAbilities(role: MembershipRoleName): PermissionAbilities {
  return { ...ROLE_DEFAULT_ABILITIES[role] };
}

const ROLE_NOTES: Partial<Record<MembershipRoleName, string>> = {
  owner: "全部 Workspace 管理能力；Owner 变更走专门指派。",
  admin: "可管理成员并行内分配非 Owner 角色。",
  tutor: "可查看成员与 Profile，参与教研协作。",
  volunteer: "可查看成员与 Profile，参与被授权的协作任务。",
  learner: "可查看成员与 Profile，编辑自己的 Profile。",
};

function mockPermissionRow(role: MembershipRoleName): PermissionMatrixRow {
  return {
    role,
    abilities: cloneAbilities(role),
    note: ROLE_NOTES[role],
  };
}

/** 设计稿示例矩阵：五角色 × 七能力。 */
export const MOCK_PERMISSION_MATRIX: PermissionMatrixRow[] = PERMISSION_ROLE_ORDER.map(mockPermissionRow);

/** 当前用户某角色是否支持某能力。 */
export function roleHasAbility(
  row: PermissionMatrixRow,
  ability: PermissionAbility,
): boolean {
  return row.abilities[ability] === true;
}

/** 多角色并集：任一角色支持即支持。 */
export function myRolesHaveAbility(
  myRoles: MembershipRoleName[] | null | undefined,
  matrix: PermissionMatrixRow[],
  ability: PermissionAbility,
): boolean {
  if (!myRoles || myRoles.length === 0) return false;
  return myRoles.some((role) => {
    const normalizedRole = role === "member" ? "learner" : role;
    const row = matrix.find((item) => item.role === normalizedRole);
    return row ? roleHasAbility(row, ability) : false;
  });
}

function normalizeRoleName(name: string): MembershipRoleName | null {
  if (name === "member") return "learner";
  if (PERMISSION_ROLE_ORDER.includes(name as MembershipRoleName)) {
    return name as MembershipRoleName;
  }
  return null;
}

/**
 * 将 #66 旧 permissionMatrix（owner/admin/member + 六项旧能力）映射为设计稿
 * 的五角色 × 七能力矩阵。缺失的 Tutor/Volunteer/Learner 用默认模板补齐。
 */
export function mapPermissionMatrixRows(
  rows: RbacPermissionMatrixRow[] | null | undefined,
): PermissionMatrixRow[] {
  if (!rows || !Array.isArray(rows) || rows.length === 0) return [];

  const mapped = new Map<MembershipRoleName, PermissionMatrixRow>();
  for (const backendRow of rows) {
    const role = normalizeRoleName(backendRow.name);
    if (!role || mapped.has(role)) continue;

    const abilities = cloneAbilities(role);
    const legacy = backendRow.abilities;
    if (role === "owner" || role === "admin") {
      abilities.view_members = legacy.list_members;
      abilities.manage_members = legacy.manage_members;
      abilities.assign_roles = legacy.assign_roles;
    }

    mapped.set(role, {
      role,
      abilities,
      note: ROLE_NOTES[role],
    });
  }

  return PERMISSION_ROLE_ORDER.map((role) => mapped.get(role) ?? mockPermissionRow(role));
}

/** 获取角色 → 能力矩阵；mock/GraphQL 切换由 workspaces 数据层开关控制。 */
export async function fetchPermissionsMatrix(): Promise<PermissionMatrixRow[]> {
  if (USE_MOCK_WORKSPACES) {
    return Promise.resolve(MOCK_PERMISSION_MATRIX.map((row) => ({ ...row, abilities: { ...row.abilities } })));
  }
  const { data } = await client.query({ query: PERMISSION_MATRIX });
  return mapPermissionMatrixRows(data?.permissionMatrix?.roles);
}

/** 保留 #66 动态能力查询，供后续页面接入真实 can? 结果。 */
export async function fetchMyAbilities(workspaceId: string): Promise<RbacAbility[]> {
  if (USE_MOCK_WORKSPACES) {
    return Promise.resolve(["view_workspace", "access_invite_only"]);
  }
  const { data } = await client.query({ query: MY_ABILITIES, variables: { workspaceId } });
  return (data?.myAbilities?.abilities ?? []) as RbacAbility[];
}

/** 角色展示辅助（复用 Workspace 角色契约）。 */
export const PERMISSION_ROLE_LABEL = ROLE_LABEL;
export const PERMISSION_ROLE_LABEL_ZH = ROLE_LABEL_ZH;
export const PERMISSION_ROLE_BADGE_CLASS = ROLE_BADGE_CLASS;
