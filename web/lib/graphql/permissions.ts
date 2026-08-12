import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #67/#66 Rbac GraphQL 契约（对齐后端 schema，#1 能力接口收敛）。
 *
 * 与后端工程师确认的契约（backend/priv/graphql/schema.graphql）：
 * - permissionMatrix（需登录，匿名返回 unauthorized）：
 *     query { permissionMatrix { roles { name abilities { name allowed } } } }
 *   返回六角色 × 六能力矩阵。abilities 为通用 [{name, allowed}] 列表
 *   （#1 收敛：不再固定六个字段，新增能力自动透传；能力词汇唯一真源在后端
 *   Rbac.abilities_list/0，契约工件 backend/priv/rbac_contract.json 做守卫）。
 * - myAbilities 已退役（#1）：能力列表随 meWorkspaces.myAbilities 下发，
 *   由后端 Rbac.abilities_for/2 单源派生。
 */

/* ---------------- 类型（对齐 backend/priv/graphql/schema.graphql） ---------------- */

/**
 * 能力名（业务枚举字符串，snake_case）。
 * 静态展示词汇：用于 PERMISSION_ABILITIES 标签键，由契约测试
 * （permissions.contract.test.ts + backend rbac_contract.json）守卫同步。
 */
export type RbacAbility =
	| "view_workspace"
	| "access_invite_only"
	| "list_members"
	| "manage_members"
	| "assign_roles"
	| "update_join_policy"
	| "create_workspace";

/** permissionMatrix 单行 abilities 的通用能力项（#1：通用列表，不再固定字段） */
export interface RbacAbilityGrant {
	name: string;
	allowed: boolean;
}

/** permissionMatrix 单行（后端返回 name + abilities 列表） */
export interface RbacPermissionMatrixRow {
	name: string;
	abilities: RbacAbilityGrant[];
}

/** permissionMatrix payload */
export interface PermissionMatrixPayload {
	roles: RbacPermissionMatrixRow[];
}

/* ---------------- 真实 query ---------------- */

/** #66 permissionMatrix：六角色 × 六能力矩阵（需登录；#1 abilities 为通用列表） */
export const PERMISSION_MATRIX: TypedDocumentNode<
	{ permissionMatrix: PermissionMatrixPayload },
	Record<string, never>
> = gql`
  query PermissionMatrix {
    permissionMatrix {
      roles {
        name
        abilities {
          name
          allowed
        }
      }
    }
  }
`;
