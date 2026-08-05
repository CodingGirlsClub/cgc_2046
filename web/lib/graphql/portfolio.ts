import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

/**
 * #P1 PortfolioItem GraphQL 契约（对齐后端 P1 commit 56b5ce2）。
 *
 * 关键约定（与后端工程师确认）：
 * - myPortfolio 查询：当前用户作品集条目列表，返回 { id title description url icon }。
 * - icon 为 String 而非 enum：取值 "document" | "book" | "guide"，与前端 mock 类型一致。
 * - createPortfolioItem input：title 必填，description/url/icon 可选；user_id 后端自动填 actor（GraphQL 不可写，防伪造）。
 * - updatePortfolioItem(id, input)：仅本人可更新自己的条目。
 * - deletePortfolioItem(id)：仅本人可删除。
 * - Result 类型：{ result, errors }，errors[0].message 供前端展示。
 */

/* ---------------- 类型 ---------------- */

/** 作品图标类型（后端 String 契约，取值 document/book/guide） */
export type PortfolioIcon = "document" | "book" | "guide";

export interface PortfolioItem {
  id: string;
  /** 所属用户 ID（仅本人，创建时后端自动填充） */
  userId: string;
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

export type PortfolioMutationResult = MutationResult<PortfolioItem>;

/* ---------------- 真实 query / mutation ---------------- */

/** myPortfolio：当前用户作品集条目列表 */
export const MY_PORTFOLIO: TypedDocumentNode<
  { myPortfolio: PortfolioItem[] | null },
  Record<string, never>
> = gql`
  query MyPortfolio {
    myPortfolio {
      id
      userId
      title
      description
      url
      icon
    }
  }
`;

/** createPortfolioItem：新建作品集条目（user_id 自动为当前用户） */
export const CREATE_PORTFOLIO_ITEM: TypedDocumentNode<
  { createPortfolioItem: PortfolioMutationResult },
  { input: CreatePortfolioItemInput }
> = gql`
  mutation CreatePortfolioItem($input: CreatePortfolioItemInput!) {
    createPortfolioItem(input: $input) {
      result {
        id
        userId
        title
        description
        url
        icon
      }
      errors {
        message
        code
      }
    }
  }
`;

/** updatePortfolioItem：更新自己的作品集条目 */
export const UPDATE_PORTFOLIO_ITEM: TypedDocumentNode<
  { updatePortfolioItem: PortfolioMutationResult },
  { id: string; input: UpdatePortfolioItemInput }
> = gql`
  mutation UpdatePortfolioItem($id: ID!, $input: UpdatePortfolioItemInput!) {
    updatePortfolioItem(id: $id, input: $input) {
      result {
        id
        userId
        title
        description
        url
        icon
      }
      errors {
        message
        code
      }
    }
  }
`;

/** deletePortfolioItem：删除自己的作品集条目 */
export const DELETE_PORTFOLIO_ITEM: TypedDocumentNode<
  { deletePortfolioItem: PortfolioMutationResult },
  { id: string }
> = gql`
  mutation DeletePortfolioItem($id: ID!) {
    deletePortfolioItem(id: $id) {
      result {
        id
        userId
        title
        description
        url
        icon
      }
      errors {
        message
        code
      }
    }
  }
`;
