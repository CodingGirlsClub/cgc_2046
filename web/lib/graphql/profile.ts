import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #69/#P1 个人资料 GraphQL 契约（对齐后端 #68 commit 4bd4165 + P1 bd22063）。
 *
 * 关键约定：
 * - 当前用户查询：`me`（#68 定稿命名，非 currentUser）。
 * - updateProfile input：displayName 必填（trim 后非空），avatarUrl 可选。
 * - P1 扩展（bd22063）：me 新增 location/about/skills/visibility/memberNumber/joinedAt；
 *   updateProfile input 增加 location/about/skills/visibility（均可选，未传不覆盖）。
 * - avatarUrl 校验（后端）：data URL 限 image/png|jpeg|webp|gif 且 ≤2.2MB；
 *   http(s) URL 限 2048 字符。
 */

/* ---------------- 类型 ---------------- */

/** 资料可见范围（P1：workspace_members 仅工作区成员 / workspace_public 工作区内公开） */
export type ProfileVisibility = "workspace_members" | "workspace_public";

export interface ProfileUser {
  id: string;
  email: string;
  /** 展示名（可编辑） */
  displayName?: string | null;
  /** 头像 URL（可空；为空时前端以首字母圆形兜底；data URL / http(s) URL 均可） */
  avatarUrl?: string | null;
  /** 平台管理员（createWorkspace 等平台级能力依据） */
  isPlatformAdmin: boolean;
  /** 所在地（P1 扩展，可编辑） */
  location?: string | null;
  /** 个人简介（P1 扩展，可编辑） */
  about?: string | null;
  /** 技能标签列表（P1 扩展，可编辑，默认 []） */
  skills?: string[] | null;
  /** 资料可见范围（P1 扩展，默认 workspace_members） */
  visibility?: ProfileVisibility | null;
  /** 平台级成员编号（P1 只读，格式 CGC-XXXXXX） */
  memberNumber?: string | null;
  /** 注册（加入）时间（P1 只读） */
  joinedAt?: string | null;
}

export interface UpdateProfileInput {
  /** 展示名（#68 契约必填，trim 后非空） */
  displayName: string;
  /** 头像 URL（可选，后端 #68 契约 avatarUrl: String；P1 支持 data URL / http(s) URL） */
  avatarUrl?: string | null;
  /** 所在地（P1 可选） */
  location?: string | null;
  /** 个人简介（P1 可选） */
  about?: string | null;
  /** 技能标签列表（P1 可选） */
  skills?: string[] | null;
  /** 资料可见范围（P1 可选） */
  visibility?: ProfileVisibility | null;
}

/* ---------------- 真实 query / mutation ---------------- */

/** 当前用户资料查询（#68 定稿 `me` + P1 扩展字段） */
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
      location
      about
      skills
      visibility
      memberNumber
      joinedAt
    }
  }
`;

/** 更新当前用户资料（#68 定稿 updateProfile + P1 扩展 input/selection） */
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
      location
      about
      skills
      visibility
      memberNumber
      joinedAt
    }
  }
`;
