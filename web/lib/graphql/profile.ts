import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #69 个人资料 GraphQL 契约（已与后端 #68 定稿对齐，commit 4bd4165）。
 *
 * 关键约定：
 * - 当前用户查询：`me`（#68 定稿命名，非 currentUser）。
 * - updateProfile input：displayName 必填（trim 后非空），avatarUrl 可选。
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
  /** 展示名（#68 契约必填，trim 后非空） */
  displayName: string;
  /** 头像 URL（可选，后端 #68 契约 avatarUrl: String） */
  avatarUrl?: string | null;
}

/* ---------------- 真实 query / mutation ---------------- */

/** 当前用户资料查询（#68 定稿 `me`；字段 id/email/displayName/avatarUrl/isPlatformAdmin） */
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

/** 更新当前用户资料（#68 定稿 updateProfile；input: {displayName 必填, avatarUrl 可选}） */
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
