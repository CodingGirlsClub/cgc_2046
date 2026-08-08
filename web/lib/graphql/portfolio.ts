import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #P1 PortfolioItem GraphQL 契约（ADR-0004 per-workspace 改造）。
 *
 * - `myWorkspacePortfolio(workspaceId)`：当前用户在某工作台的作品集。
 * - `createPortfolioItem(workspaceId, input)`：在某工作台创建条目。
 * - `updatePortfolioItem(id, workspaceId, input)`：更新某工作台条目（tenant 隔离）。
 * - `deletePortfolioItem(id, workspaceId)`：删除某工作台条目（tenant 隔离）。
 *
 * Result 类型：{ result, errors }，errors[0].message 供前端展示。
 */

/* ---------------- 类型 ---------------- */

/** 作品图标类型（后端 String 契约，取值 document/book/guide） */
export type PortfolioIcon = "document" | "book" | "guide";

export interface PortfolioItem {
  id: string;
  /** 所属工作台（租户）ID */
  workspaceId: string;
  /** 作品标题（必填） */
  title: string;
  /** 作品描述（可选） */
  description?: string | null;
  /** 作品链接（可选） */
  url?: string | null;
  /** 作品图标类型（默认 document） */
  icon: PortfolioIcon;
}

export interface CreatePortfolioItemInput {
  title: string;
  description?: string | null;
  url?: string | null;
  icon?: PortfolioIcon | null;
}

export interface UpdatePortfolioItemInput {
  title?: string | null;
  description?: string | null;
  url?: string | null;
  icon?: PortfolioIcon | null;
}

/* ---------------- 真实 query / mutation ---------------- */

/** myWorkspacePortfolio：当前用户在某工作台的作品集条目列表 */
export const MY_WORKSPACE_PORTFOLIO: TypedDocumentNode<
  { myWorkspacePortfolio: PortfolioItem[] | null },
  { workspaceId: string }
> = gql`
  query MyWorkspacePortfolio($workspaceId: ID!) {
    myWorkspacePortfolio(workspaceId: $workspaceId) {
      id
      workspaceId
      title
      description
      url
      icon
    }
  }
`;

/** createPortfolioItem：在某工作台新建作品集条目（workspace_id/user_id 后端自动填充） */
export const CREATE_PORTFOLIO_ITEM: TypedDocumentNode<
  { createPortfolioItem: PortfolioItem | null },
  { workspaceId: string; input: CreatePortfolioItemInput }
> = gql`
  mutation CreatePortfolioItem($workspaceId: ID!, $input: CreatePortfolioItemInput!) {
    createPortfolioItem(workspaceId: $workspaceId, input: $input) {
      id
      workspaceId
      title
      description
      url
      icon
    }
  }
`;

/** updatePortfolioItem：更新某工作台自己的作品集条目 */
export const UPDATE_PORTFOLIO_ITEM: TypedDocumentNode<
  { updatePortfolioItem: PortfolioItem | null },
  { id: string; workspaceId: string; input: UpdatePortfolioItemInput }
> = gql`
  mutation UpdatePortfolioItem($id: ID!, $workspaceId: ID!, $input: UpdatePortfolioItemInput!) {
    updatePortfolioItem(id: $id, workspaceId: $workspaceId, input: $input) {
      id
      workspaceId
      title
      description
      url
      icon
    }
  }
`;

/** deletePortfolioItem：删除某工作台自己的作品集条目 */
export const DELETE_PORTFOLIO_ITEM: TypedDocumentNode<
  { deletePortfolioItem: PortfolioItem | null },
  { id: string; workspaceId: string }
> = gql`
  mutation DeletePortfolioItem($id: ID!, $workspaceId: ID!) {
    deletePortfolioItem(id: $id, workspaceId: $workspaceId) {
      id
      workspaceId
      title
      description
      url
      icon
    }
  }
`;
