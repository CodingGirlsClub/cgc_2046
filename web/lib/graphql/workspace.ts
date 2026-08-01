import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #63 Workspace GraphQL 契约（已按后端 #62 实际 schema 对齐，commit af974b5）。
 *
 * 关键约定（与后端工程师 worker_c5ca4e44 确认）：
 * - Workspace type：{ id, slug, name, joinPolicy, sponsorshipEnabled }
 * - getWorkspace(slug) / getWorkspaceById(id)：需登录（Bearer token），返回单个 Workspace；
 *   v1 无 list/meWorkspaces 查询（#62 范围决定），真实"我的工作台列表"由后端
 *   在 #64 membership 落地后补齐（myWorkspaces），届时前端切换真实数据。
 * - createWorkspace(input)：仅平台管理员可调，返回 CreateWorkspaceResult { result, errors }。
 */

/* ---------------- 类型（对齐 backend/priv/graphql/schema.graphql） ---------------- */

export type JoinPolicy = "open" | "request" | "invite_only";

export interface Workspace {
  id: string;
  /** 工作台唯一标识（小写字母/数字/连字符，创建者提供） */
  slug: string;
  /** 工作台名称 */
  name: string;
  /** 加入策略：open 公开直接加入 / request 公开申请审批 / invite_only 私密仅邀请 */
  joinPolicy: JoinPolicy;
  /** 是否开放赞助入口（默认开） */
  sponsorshipEnabled: boolean;
}

export interface MutationError {
  message?: string | null;
  code?: string | null;
}

export interface CreateWorkspaceInput {
  slug: string;
  name: string;
  joinPolicy?: JoinPolicy;
  sponsorshipEnabled?: boolean;
}

export interface CreateWorkspaceResultData {
  result: Workspace | null;
  errors: MutationError[];
}

/* ---------------- 真实 query / mutation ---------------- */

export const GET_WORKSPACE: TypedDocumentNode<
  { getWorkspace: Workspace | null },
  { slug: string }
> = gql`
  query GetWorkspace($slug: String!) {
    getWorkspace(slug: $slug) {
      id
      slug
      name
      joinPolicy
      sponsorshipEnabled
    }
  }
`;

export const GET_WORKSPACE_BY_ID: TypedDocumentNode<
  { getWorkspaceById: Workspace | null },
  { id: string }
> = gql`
  query GetWorkspaceById($id: ID!) {
    getWorkspaceById(id: $id) {
      id
      slug
      name
      joinPolicy
      sponsorshipEnabled
    }
  }
`;

export const CREATE_WORKSPACE: TypedDocumentNode<
  { createWorkspace: CreateWorkspaceResultData },
  { input: CreateWorkspaceInput }
> = gql`
  mutation CreateWorkspace($input: CreateWorkspaceInput!) {
    createWorkspace(input: $input) {
      result {
        id
        slug
        name
        joinPolicy
        sponsorshipEnabled
      }
      errors {
        message
        code
      }
    }
  }
`;

/* ---------------- join_policy 展示辅助 ---------------- */

export const JOIN_POLICY_LABEL: Record<JoinPolicy, string> = {
  open: "公开",
  request: "申请审批",
  invite_only: "仅邀请",
};

export const JOIN_POLICY_HINT: Record<JoinPolicy, string> = {
  open: "公开直接加入",
  request: "公开申请审批",
  invite_only: "私密仅邀请",
};
