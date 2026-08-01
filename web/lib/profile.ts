import type { MembershipRoleName } from "./graphql/workspace";
import type { UpdateProfileInput } from "./graphql/profile";
import { ME_PROFILE, UPDATE_PROFILE } from "./graphql/profile";
import { client } from "./apollo-client";
import { USE_MOCK_WORKSPACES, fetchMyWorkspaces } from "./workspaces";

/**
 * #69 个人资料数据源。
 *
 * 后端 #68 已定稿（me query + updateProfile mutation，commit 4bd4165）：
 * USE_MOCK_WORKSPACES = false 走真实 GraphQL（fetchCurrentProfile /
 * updateCurrentProfile / fetchProfileRoleSummary），mock 数据保留作兜底
 * （切换 USE_MOCK_WORKSPACES = true 可回到 mock，便于本地无后端联调）。
 * 调用方（app/profile/page.tsx、ProfileEntry 组件）无需改动。
 */

export interface CurrentProfile {
  id: string;
  email: string;
  /** 展示名（可编辑字段；编辑保存后 mock 内存更新） */
  displayName?: string | null;
  /** 头像 URL（可空；为空时前端以首字母圆形兜底） */
  avatarUrl?: string | null;
  /** 平台管理员 */
  isPlatformAdmin: boolean;
}

/** 角色汇总条目：当前用户在某个可进入 Workspace 的角色并集 */
export interface ProfileRoleSummary {
  workspaceId: string;
  workspaceSlug: string;
  workspaceName: string;
  /** 当前用户在该工作台的角色名数组（非成员/受邀未加入为 []） */
  myRoleNames: MembershipRoleName[];
}

/** mock：当前登录用户（与 #63 mock 工作台 myRoleNames 语义一致） */
export const MOCK_CURRENT_PROFILE: CurrentProfile = {
  id: "u_0202",
  email: "xiaomei@example.com",
  displayName: "小美",
  avatarUrl: null,
  isPlatformAdmin: false,
};

/**
 * 获取当前用户资料。
 *
 * 后端 #68 已定稿：真实分支走 `me` query（需登录，Bearer token 自动附加）。
 */
export async function fetchCurrentProfile(): Promise<CurrentProfile> {
  if (USE_MOCK_WORKSPACES) {
    return Promise.resolve({ ...MOCK_CURRENT_PROFILE });
  }
  const { data } = await client.query({ query: ME_PROFILE });
  return (
    data?.me ?? {
      id: "",
      email: "",
      displayName: null,
      avatarUrl: null,
      isPlatformAdmin: false,
    }
  );
}

/**
 * 更新当前用户资料（mock：内存更新 MOCK_CURRENT_PROFILE，成功后重新 fetch 拿到新值）。
 * 真实：调用后端 updateProfile mutation（#68 定稿：input.displayName 必填，avatarUrl 可选）。
 */
export async function updateCurrentProfile(
  input: UpdateProfileInput,
): Promise<CurrentProfile> {
  if (USE_MOCK_WORKSPACES) {
    if (typeof input.displayName === "string" && input.displayName.trim() !== "") {
      MOCK_CURRENT_PROFILE.displayName = input.displayName;
    }
    return Promise.resolve({ ...MOCK_CURRENT_PROFILE });
  }
  const { data } = await client.mutate({
    mutation: UPDATE_PROFILE,
    variables: { input },
  });
  return (
    data?.updateProfile ?? {
      id: "",
      email: "",
      displayName: null,
      avatarUrl: null,
      isPlatformAdmin: false,
    }
  );
}

/**
 * 角色汇总：当前用户所进入 Workspace + 各工作台角色并集。
 * 数据源复用 #63 fetchMyWorkspaces（真实分支走后端 meWorkspaces，
 * 用 exists(memberships) 过滤：受邀无 membership 的用户不返回，
 * 故真实数据下角色汇总不会出现"受邀未加入"行；有 membership 但角色
 * 被清空（assignRoles 空数组）时 myRoleNames=[]，展示"无角色"）。
 * 展示时仅列当前用户已进入（可访问）的工作台。
 */
export async function fetchProfileRoleSummary(): Promise<ProfileRoleSummary[]> {
  const workspaces = await fetchMyWorkspaces();
  return workspaces.map((w) => ({
    workspaceId: w.id,
    workspaceSlug: w.slug,
    workspaceName: w.name,
    myRoleNames: w.myRoleNames ?? [],
  }));
}
