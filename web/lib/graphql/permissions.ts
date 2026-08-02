import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #67/#66 Rbac GraphQL 契约（对齐后端 #66 schema commit 2fdf506）。
 *
 * 与后端工程师 worker_c5ca4e44 确认的契约（backend/priv/graphql/schema.graphql）：
 * - permissionMatrix（需登录，匿名返回 unauthorized）：
 *     query { permissionMatrix { roles { name abilities { viewWorkspace accessInviteOnly
 *       listMembers manageMembers assignRoles createWorkspace } } } }
 *   返回 owner/admin/member 三角色 × 六能力 boolean。字段名与 SDL 对齐为 camelCase
 *   （后端 Absinthe 默认 camelize；P1-5 起前端不再依赖 snake_case 宽松匹配兜底）。
 * - myAbilities(workspaceId: ID!)（需登录）：
 *     query { myAbilities(workspaceId: "xxx") { abilities } }
 *   返回当前用户在该工作台能力名列表（如 ["view_workspace","access_invite_only",...]）。
 *   注意：abilities 数组元素是业务枚举数据（能力名，snake_case），不是 GraphQL 字段名，
 *   与 permissionMatrix.abilities 的 camelCase 字段名是两个维度，不互相影响。
 */

/* ---------------- 类型（对齐 backend/priv/graphql/schema.graphql） ---------------- */

/**
 * 能力名（后端 myAbilities 返回的业务枚举字符串，snake_case）。
 * 这是业务数据而非 GraphQL 字段名，不随 P1-5 字段名统一改（避免牵连 myAbilities resolver）。
 */
export type RbacAbility =
  | "view_workspace"
  | "access_invite_only"
  | "list_members"
  | "manage_members"
  | "assign_roles"
  | "create_workspace";

/** permissionMatrix 单行 abilities（后端返回六能力 boolean，字段名 camelCase） */
export interface RbacPermissionAbilities {
  viewWorkspace: boolean;
  accessInviteOnly: boolean;
  listMembers: boolean;
  manageMembers: boolean;
  assignRoles: boolean;
  createWorkspace: boolean;
}

/** permissionMatrix 单行（后端返回 name + abilities） */
export interface RbacPermissionMatrixRow {
  name: string;
  abilities: RbacPermissionAbilities;
}

/** permissionMatrix payload */
export interface PermissionMatrixPayload {
  roles: RbacPermissionMatrixRow[];
}

/** myAbilities payload */
export interface MyAbilitiesPayload {
  abilities: string[];
}

/* ---------------- 真实 query ---------------- */

/** #66 permissionMatrix：三角色 × 六能力静态矩阵（需登录） */
export const PERMISSION_MATRIX: TypedDocumentNode<
  { permissionMatrix: PermissionMatrixPayload },
  Record<string, never>
> = gql`
  query PermissionMatrix {
    permissionMatrix {
      roles {
        name
        abilities {
          viewWorkspace
          accessInviteOnly
          listMembers
          manageMembers
          assignRoles
          createWorkspace
        }
      }
    }
  }
`;

/** #66 myAbilities：当前用户在指定工作台的能力名列表（需登录） */
export const MY_ABILITIES: TypedDocumentNode<
  { myAbilities: MyAbilitiesPayload },
  { workspaceId: string }
> = gql`
  query MyAbilities($workspaceId: ID!) {
    myAbilities(workspaceId: $workspaceId) {
      abilities
    }
  }
`;
