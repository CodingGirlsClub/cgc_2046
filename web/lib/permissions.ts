import type { MembershipRoleName } from "./graphql/workspace";
import { ROLE_BADGE_CLASS, ROLE_LABEL, ROLE_LABEL_ZH, ROLE_NAMES } from "./graphql/workspace";
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
 * 单一数据源 = 后端 RBAC 真实能力（rbac.ex @abilities + GraphQL schema 六项）：
 * view_workspace / access_invite_only / list_members / manage_members /
 * assign_roles / create_workspace。设计稿曾多出 4 项无后端授权的假能力
 * （修改加入策略 / 查看资料 / 编辑自己资料 / 跨工作区访问），
 * 已按用户拍板砍掉，页面不再凭空画格子。
 *
 * 矩阵以五个默认角色展示：Owner / Admin / Tutor / Volunteer / Learner。
 * 后端返回六角色（含 member），前端 normalize member→learner 后按五角色渲染；
 * mock 模式与后端缺行时用模板补齐（模板只含六能力）。
 */

/** 能力 ID：与后端 RbacAbility 对齐（单一数据源，避免再次漂移）。 */
export type PermissionAbility = RbacAbility;

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

/**
 * 设计稿固定的默认角色顺序（五角色，不含 member）。
 * 由 ROLE_NAMES 单源过滤派生，避免重复六角色字面量；旧 member 只作为兼容输入，不出现在正式矩阵。
 */
export const PERMISSION_ROLE_ORDER: MembershipRoleName[] = ROLE_NAMES.filter(
  (role) => role !== "member",
);

export const PERMISSION_ABILITIES: PermissionAbilityDef[] = [
  {
    id: "view_workspace",
    label: "查看工作台",
    description: "查看当前 Workspace 的概览与基本信息。",
  },
  {
    id: "access_invite_only",
    label: "访问仅邀请",
    description: "访问 invite_only 加入策略的 Workspace。",
  },
  {
    id: "list_members",
    label: "查看成员列表",
    description: "查看当前 Workspace 的成员列表与成员角色并集。",
  },
  {
    id: "manage_members",
    label: "管理成员",
    description: "添加、移除或管理当前 Workspace 的成员关系。",
  },
  {
    id: "assign_roles",
    label: "分配角色",
    description: "在成员页调整 Owner 之外的角色；Owner 走专门指派流程。",
  },
  {
    id: "create_workspace",
    label: "创建工作台",
    description: "创建新的 Workspace（平台级能力，不随角色在矩阵中授予）。",
  },
];

type PermissionAbilities = Record<PermissionAbility, boolean>;

const OWNER_ABILITIES: PermissionAbilities = {
  view_workspace: true,
  access_invite_only: true,
  list_members: true,
  manage_members: true,
  assign_roles: true,
  create_workspace: false,
};

const ADMIN_ABILITIES: PermissionAbilities = {
  ...OWNER_ABILITIES,
};

const MEMBER_ABILITIES: PermissionAbilities = {
  view_workspace: true,
  access_invite_only: true,
  list_members: false,
  manage_members: false,
  assign_roles: false,
  create_workspace: false,
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

/** 设计稿示例矩阵：五角色 × 六能力（与后端 schema 字段一一对应）。 */
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
 * 将后端 permissionMatrix（六角色 × 六能力）映射为五角色矩阵（member→learner）。
 * 六能力直接从后端 abilities 字段直取（viewWorkspace/accessInviteOnly/
 * listMembers/manageMembers/assignRoles/createWorkspace）；后端缺行时用模板补齐。
 */
export function mapPermissionMatrixRows(
  rows: RbacPermissionMatrixRow[] | null | undefined,
): PermissionMatrixRow[] {
  if (!rows || !Array.isArray(rows) || rows.length === 0) return [];

  const mapped = new Map<MembershipRoleName, PermissionMatrixRow>();
  for (const backendRow of rows) {
    const role = normalizeRoleName(backendRow.name);
    if (!role || mapped.has(role)) continue;

    const backend = backendRow.abilities;
    mapped.set(role, {
      role,
      abilities: {
        view_workspace: backend.viewWorkspace,
        access_invite_only: backend.accessInviteOnly,
        list_members: backend.listMembers,
        manage_members: backend.manageMembers,
        assign_roles: backend.assignRoles,
        create_workspace: backend.createWorkspace,
      },
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
