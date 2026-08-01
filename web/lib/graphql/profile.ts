import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #69 个人资料 GraphQL 契约。
 *
 * 关键约定：
 * - 当前用户查询建议 me/currentUser（与后端 #68 对齐；若 #68 定稿有差异以后端为准）。
 *   当前实现先按 `me` 写骨架；USE_MOCK 模式下不触发真实查询，后端 #68 完成后微调字段即可。
 * - 可编辑字段：displayName（展示名）。avatarUrl 仅展示（后端若有上传能力再扩展）。
 */

/* ---------------- 类型 ---------------- */

export interface ProfileUser {
  id: string;
  email: string;
  /** 展示名（可编辑） */
  displayName?: string | null;
  /** 头像 URL（可空；为空时前端以首字母圆形兜底） */
  avatarUrl?: string | null;
  /** 平台管理员（createWorkspace 等平台级能力依据） */
  isPlatformAdmin: boolean;
}

export interface UpdateProfileInput {
  displayName?: string | null;
}

/* ---------------- 真实 query / mutation ---------------- */

/** 当前用户资料查询（建议 me；后端 #68 定稿后按实际字段微调） */
export const ME_PROFILE: TypedDocumentNode<
  { me: ProfileUser | null },
  Record<string, never>
> = gql`
  query MeProfile {
    me {
      id
      email
      displayName
      avatarUrl
      isPlatformAdmin
    }
  }
`;

/** 更新当前用户资料（可编辑字段：displayName） */
export const UPDATE_PROFILE: TypedDocumentNode<
  { updateProfile: ProfileUser | null },
  { input: UpdateProfileInput }
> = gql`
  mutation UpdateProfile($input: UpdateProfileInput!) {
    updateProfile(input: $input) {
      id
      email
      displayName
      avatarUrl
      isPlatformAdmin
    }
  }
`;
