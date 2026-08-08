import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #69/#P1 个人资料 GraphQL 契约（ADR-0004 per-workspace 改造）。
 *
 * 关键约定：
 * - `me`：全局身份（id/email/displayName/isPlatformAdmin/memberNumber/joinedAt），
 *   profile 字段（avatarUrl/location/about/skills/visibility/uiThemePreference）已迁至
 *   `workspaceProfile`（per-workspace）。
 * - `workspaceProfile(workspaceId)`：当前用户在某工作台的档案。
 * - `updateWorkspaceProfile(workspaceId, input)`：更新某工作台档案。
 * - `updateDisplayName(displayName)`：更新全局显示名（全局身份字段）。
 * - `setWorkspaceTheme(workspaceId, input)`：per-workspace 主题。
 * - avatarUrl 校验（后端）：data URL 限 image/png|jpeg|webp|gif 且 ≤2.2MB；
 *   http(s) URL 限 2048 字符。
 */

/* ---------------- 类型 ---------------- */

/** 资料可见范围（2026-08-02 三档对齐：public 全站公开 / workspace 该工作区公开 / only_me 仅自己可见） */
export type ProfileVisibility = "public" | "workspace" | "only_me";

/** 全局身份（me） */
export interface MeUser {
  id: string;
  email: string;
  /** 展示名（全局身份字段，可编辑） */
  displayName?: string | null;
  /** 平台管理员（createWorkspace 等平台级能力依据） */
  isPlatformAdmin: boolean;
  /** 平台级成员编号（只读，格式 CGC-XXXXXX） */
  memberNumber?: string | null;
  /** 注册（加入）时间（只读） */
  joinedAt?: string | null;
}

/** per-workspace 档案（workspaceProfile / updateWorkspaceProfile / setWorkspaceTheme） */
export interface WorkspaceProfileUser {
  id: string;
  workspaceId: string;
  userId: string;
  /** 头像 URL（可空；为空时前端以首字母圆形兜底；data URL / http(s) URL 均可） */
  avatarUrl?: string | null;
  /** 所在地（可编辑） */
  location?: string | null;
  /** 个人简介（可编辑） */
  about?: string | null;
  /** 技能标签列表（可编辑，默认 []） */
  skills?: string[] | null;
  /** 资料可见范围（默认 only_me） */
  visibility?: ProfileVisibility | null;
  /** UI 主题偏好（U3）：dark | light，per-workspace 持久化 */
  uiThemePreference: string;
}

export interface UpdateWorkspaceProfileInput {
  avatarUrl?: string | null;
  location?: string | null;
  about?: string | null;
  skills?: string[] | null;
  visibility?: ProfileVisibility | null;
}

/* ---------------- 真实 query / mutation ---------------- */

/** 当前用户全局身份查询（ADR-0004 收窄：仅全局身份字段） */
export const ME_PROFILE: TypedDocumentNode<
  { me: MeUser | null },
  Record<string, never>
> = gql`
  query MeProfile {
    me {
      id
      email
      displayName
      isPlatformAdmin
      memberNumber
      joinedAt
    }
  }
`;

/** 当前用户在某工作台的档案查询（ADR-0004 per-workspace） */
export const WORKSPACE_PROFILE: TypedDocumentNode<
  { workspaceProfile: WorkspaceProfileUser | null },
  { workspaceId: string }
> = gql`
  query WorkspaceProfile($workspaceId: ID!) {
    workspaceProfile(workspaceId: $workspaceId) {
      id
      workspaceId
      userId
      avatarUrl
      location
      about
      skills
      visibility
      uiThemePreference
    }
  }
`;

/** 更新当前用户全局显示名（ADR-0004：displayName 保留全局身份字段） */
export const UPDATE_DISPLAY_NAME: TypedDocumentNode<
  { updateDisplayName: MeUser | null },
  { displayName: string }
> = gql`
  mutation UpdateDisplayName($displayName: String!) {
    updateDisplayName(displayName: $displayName) {
      id
      email
      displayName
      isPlatformAdmin
      memberNumber
      joinedAt
    }
  }
`;

/** 更新当前用户在某工作台的档案（ADR-0004 per-workspace） */
export const UPDATE_WORKSPACE_PROFILE: TypedDocumentNode<
  { updateWorkspaceProfile: WorkspaceProfileUser | null },
  { workspaceId: string; input: UpdateWorkspaceProfileInput }
> = gql`
  mutation UpdateWorkspaceProfile($workspaceId: ID!, $input: UpdateWorkspaceProfileInput!) {
    updateWorkspaceProfile(workspaceId: $workspaceId, input: $input) {
      id
      workspaceId
      userId
      avatarUrl
      location
      about
      skills
      visibility
      uiThemePreference
    }
  }
`;

/** 设置当前用户在某工作台的 UI 主题偏好（ADR-0004 per-workspace） */
export const SET_WORKSPACE_THEME: TypedDocumentNode<
  { setWorkspaceTheme: WorkspaceProfileUser | null },
  { workspaceId: string; input: { uiThemePreference: string } }
> = gql`
  mutation SetWorkspaceTheme($workspaceId: ID!, $input: SetWorkspaceThemeInput!) {
    setWorkspaceTheme(workspaceId: $workspaceId, input: $input) {
      id
      workspaceId
      userId
      uiThemePreference
    }
  }
`;
