import type { JoinPolicy } from "./graphql/workspace";

/**
 * #63 工作台列表数据源。
 *
 * 后端 #62 已完成（getWorkspace/getWorkspaceById/createWorkspace 真实可用），
 * 但 v1 无 list/meWorkspaces 查询（Leader 拍板：真实"我的工作台列表"语义依赖
 * #64 membership，后端 #64 后补齐 myWorkspaces，届时通知前端切换真实数据）。
 *
 * 当前：mock 数据（USE_MOCK_WORKSPACES = true）——验收标准以 UI/交互/路由为主。
 * 切换真实数据：改 USE_MOCK_WORKSPACES = false 并实现 fetchMyWorkspaces()，
 * 调用方（app/page.tsx 工作台）不需要改。
 */

export interface WorkspaceListItem {
  id: string;
  slug: string;
  name: string;
  joinPolicy: JoinPolicy;
  sponsorshipEnabled: boolean;
  /** 展示附加字段（mock；真实 myWorkspaces 返回后由后端补齐语义） */
  description?: string;
  memberCount?: number;
  unreadCount?: number;
  roles?: string[];
  membershipStatus?: "active" | "pending" | "invited";
}

export const USE_MOCK_WORKSPACES = true;

/** mock：贴合后端 Workspace 真实字段（slug/name/joinPolicy/sponsorshipEnabled） */
export const MOCK_WORKSPACES: WorkspaceListItem[] = [
  {
    id: "ws_01",
    slug: "cgc-shanghai",
    name: "CGC 上海分社",
    joinPolicy: "open",
    sponsorshipEnabled: true,
    description: "上海线下活动 + 线上学院课程，面向全平台开放加入。",
    memberCount: 128,
    unreadCount: 3,
    roles: ["member"],
    membershipStatus: "active",
  },
  {
    id: "ws_02",
    slug: "cgc-academy",
    name: "CGC 线上学院",
    joinPolicy: "request",
    sponsorshipEnabled: true,
    description: "系统化编程课程与教研中心，需申请审批后加入。",
    memberCount: 342,
    unreadCount: 0,
    roles: ["admin", "teacher"],
    membershipStatus: "active",
  },
  {
    id: "ws_03",
    slug: "cgc-sponsor-hub",
    name: "赞助商俱乐部",
    joinPolicy: "invite_only",
    sponsorshipEnabled: false,
    description: "核心赞助商私密空间，仅凭邀请加入。",
    memberCount: 24,
    unreadCount: 0,
    roles: [],
    membershipStatus: "invited",
  },
];

/**
 * 获取当前用户可进入的 Workspace 列表。
 *
 * TODO(#64)：后端 myWorkspaces 查询就绪后，将 USE_MOCK_WORKSPACES 置 false，
 * 并在此改为真实 GraphQL query（需登录，Bearer token 由 apollo authLink 自动附加）。
 */
export async function fetchMyWorkspaces(): Promise<WorkspaceListItem[]> {
  if (USE_MOCK_WORKSPACES) {
    return Promise.resolve(MOCK_WORKSPACES);
  }
  // TODO(#64): 真实 myWorkspaces 查询落点
  return [];
}
