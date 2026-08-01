import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #67/#66 Rbac GraphQL 契约（对齐后端 #66 schema commit 2fdf506）。
 *
 * 与后端工程师 worker_c5ca4e44 确认的契约（backend/priv/graphql/schema.graphql）：
 * - permissionMatrix（需登录，匿名返回 unauthorized）：
 *     query { permissionMatrix { roles { name abilities { view_workspace access_invite_only
 *       list_members manage_members assign_roles create_workspace } } } }
 *   返回 owner/admin/member 三角色 × 六能力 boolean，与 lib/permissions.ts
 *   PermissionMatrixRow 完全对齐（abilities 字段即 snake_case 能力名）。
 * - myAbilities(workspaceId: ID!)（需登录）：
 *     query { myAbilities(workspaceId: "xxx") { abilities } }
 *   返回当前用户在该工作台能力名列表（如 ["view_workspace","access_invite_only",...]）。
 */

/* ---------------- 类型（对齐 backend/priv/graphql/schema.graphql） ---------------- */

/** 能力名（后端 Rbac abilities 的 snake_case 字符串，与前端 PermissionAbility 一致） */
export type RbacAbility =
  | "view_workspace"
  | "access_invite_only"
  | "list_members"
  | "manage_members"
  | "assign_roles"
  | "create_workspace";

/** permissionMatrix 单行 abilities（后端返回六能力 boolean） */
export interface RbacPermissionAbilities {
  view_workspace: boolean;
  access_invite_only: boolean;
  list_members: boolean;
  manage_members: boolean;
  assign_roles: boolean;
  create_workspace: boolean;
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
          view_workspace
          access_invite_only
          list_members
          manage_members
          assign_roles
          create_workspace
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
