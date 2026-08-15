import type { MembershipRoleName } from "./graphql/workspace";
import type {
  MeUser,
  ProfileVisibility,
  UpdateWorkspaceProfileInput,
  WorkspaceProfileUser,
} from "./graphql/profile";
import {
  ME_PROFILE,
  UPDATE_DISPLAY_NAME,
  UPDATE_WORKSPACE_PROFILE,
  WORKSPACE_PROFILE,
} from "./graphql/profile";
import {
  MY_WORKSPACE_PORTFOLIO,
  CREATE_PORTFOLIO_ITEM,
  UPDATE_PORTFOLIO_ITEM,
  DELETE_PORTFOLIO_ITEM,
  type CreatePortfolioItemInput,
  type PortfolioItem,
  type UpdatePortfolioItemInput,
} from "./graphql/portfolio";
import { client } from "./apollo-client";
import { fetchMyWorkspaces } from "./workspaces";
import { formatJoinedDate } from "./format";

/**
 * #69/#P1 个人资料数据源（ADR-0004 per-workspace 改造）。
 *
 * 唯一真实路径 = GraphQL。ADR-0004 后：
 * - `fetchCurrentProfile`：me（全局身份 id/email/displayName/isPlatformAdmin/memberNumber/joinedAt）。
 * - `fetchWorkspaceProfile(workspaceId)` / `updateWorkspaceProfile(workspaceId, input)`：
 *   per-workspace 档案（avatar/location/about/skills/visibility）。
 * - `updateDisplayName(name)`：全局显示名（全局身份字段）。
 * - Portfolio CRUD 全部带 workspaceId（tenant 隔离）。
 */

/* ---------------- 头像上传限制（与后端契约对齐的单一数据源） ----------------
 * 后端校验见 lib/graphql/profile.ts：data URL 限 image/png|jpeg|webp|gif 且 ≤2.2MB。
 * 前端 UI 提示文案与上传校验共用此常量，避免后端调整时文案/校验漂移。
 */
export const AVATAR_MAX_MB = 2.2;
/** 头像文件大小上限（bytes） */
export const AVATAR_MAX_BYTES = AVATAR_MAX_MB * 1024 * 1024;
/** 头像允许的 MIME 白名单（与后端一致） */
export const AVATAR_ALLOWED_TYPES = [
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
] as const;
export type AvatarMimeType = (typeof AVATAR_ALLOWED_TYPES)[number];
/** MIME → 展示名（格式提示/错误文案共用） */
export const AVATAR_TYPE_LABEL: Record<AvatarMimeType, string> = {
	"image/png": "PNG",
	"image/jpeg": "JPG",
	"image/webp": "WebP",
	"image/gif": "GIF",
};

export interface CurrentProfile {
  id: string;
  email: string;
  /** 展示名（全局身份字段，可编辑） */
  displayName?: string | null;
  /** 平台管理员 */
  isPlatformAdmin: boolean;
  /** 平台级成员编号（只读） */
  memberNumber?: string | null;
  /** 注册（加入）时间（只读） */
  joinedAt?: string | null;
  workspaceName?: string | null;
  workspaceSlug?: string | null;
  workspaceRoles?: MembershipRoleName[] | null;
}

/** per-workspace 档案（页面层视图模型输入） */
export interface WorkspaceProfileContent {
  id: string;
  workspaceId: string;
  userId: string;
  avatarUrl: string | null;
  location: string | null;
  about: string | null;
  skills: string[];
  visibility: ProfileVisibility;
  uiThemePreference: string;
  portfolio: ProfilePortfolioItem[];
}

export type PortfolioIcon = "document" | "book" | "guide";

export interface ProfilePortfolioItem {
  id: string;
  workspaceId: string;
  title: string;
  description: string;
  url?: string | null;
  icon?: PortfolioIcon;
}

/** 角色汇总条目：当前用户在某个可进入 Workspace 的角色并集 */
export interface ProfileRoleSummary {
  workspaceId: string;
  workspaceSlug: string;
  workspaceName: string;
  /** 当前用户在该工作台的角色名数组（非成员/受邀未加入为 []） */
  myRoleNames: MembershipRoleName[];
}

/** 后端 PortfolioItem → 前端展示条目（icon 兜底 document） */
export function mapPortfolioItem(item: PortfolioItem): ProfilePortfolioItem {
  return {
    id: item.id,
    workspaceId: item.workspaceId,
    title: item.title,
    description: item.description ?? "",
    url: item.url ?? null,
    icon: item.icon ?? "document",
  };
}

/**
 * 获取当前用户全局身份。
 * 唯一真实路径：`me` query（需登录，Bearer token 自动附加）。
 *
 * P3 去重：先 `client.readQuery` 读归一化缓存，命中则零网络返回；miss 才发网络请求。
 */
export async function fetchCurrentProfile(): Promise<CurrentProfile> {
  const cached = client.readQuery({ query: ME_PROFILE });
  if (cached?.me) {
    return mapMeToProfile(cached.me);
  }
  const { data } = await client.query({ query: ME_PROFILE });
  const me = data?.me;
  return mapMeToProfile(me ?? null);
}

function mapMeToProfile(me: MeUser | null): CurrentProfile {
  if (!me) {
    return {
      id: "",
      email: "",
      displayName: null,
      isPlatformAdmin: false,
    };
  }
  return {
    id: me.id,
    email: me.email,
    displayName: me.displayName ?? null,
    isPlatformAdmin: me.isPlatformAdmin,
    memberNumber: me.memberNumber ?? null,
    joinedAt: me.joinedAt ?? null,
  };
}

/** 后端 WorkspaceProfile → 前端视图模型 */
export function mapWorkspaceProfile(
  p: WorkspaceProfileUser | null,
): WorkspaceProfileContent | null {
  if (!p) return null;
  return {
    id: p.id,
    workspaceId: p.workspaceId,
    userId: p.userId,
    avatarUrl: p.avatarUrl ?? null,
    location: p.location ?? null,
    about: p.about ?? null,
    skills: p.skills ?? [],
    visibility: p.visibility ?? "only_me",
    uiThemePreference: p.uiThemePreference,
    portfolio: [],
  };
}

/**
 * 获取当前用户在某工作台的档案（ADR-0004 per-workspace）。
 * 唯一真实路径：workspaceProfile(workspaceId) query。
 */
export async function fetchWorkspaceProfile(
  workspaceId: string,
): Promise<WorkspaceProfileContent | null> {
  const { data } = await client.query({
    query: WORKSPACE_PROFILE,
    variables: { workspaceId },
    fetchPolicy: "network-only",
  });
  return mapWorkspaceProfile(data?.workspaceProfile ?? null);
}

/**
 * 更新当前用户在某工作台的档案（ADR-0004 per-workspace）。
 * 唯一真实路径：updateWorkspaceProfile(workspaceId, input) mutation。
 */
export async function updateWorkspaceProfile(
  workspaceId: string,
  input: UpdateWorkspaceProfileInput,
): Promise<WorkspaceProfileContent | null> {
  const { data } = await client.mutate({
    mutation: UPDATE_WORKSPACE_PROFILE,
    variables: { workspaceId, input },
  });
  return mapWorkspaceProfile(data?.updateWorkspaceProfile ?? null);
}

/**
 * 更新当前用户全局显示名（ADR-0004：displayName 保留全局身份字段）。
 */
export async function updateDisplayName(
  displayName: string,
): Promise<CurrentProfile> {
  const { data } = await client.mutate({
    mutation: UPDATE_DISPLAY_NAME,
    variables: { displayName },
  });
  return mapMeToProfile(data?.updateDisplayName ?? null);
}

/* ---------------- Portfolio 数据源（ADR-0004 per-workspace） ---------------- */

/**
 * 获取当前用户在某工作台的作品集条目。
 * 唯一真实路径：myWorkspacePortfolio(workspaceId) query。
 * network-only 保证保存后重新拉取拿到最新列表。
 */
export async function fetchPortfolioItems(
  workspaceId: string,
): Promise<ProfilePortfolioItem[]> {
  const { data } = await client.query({
    query: MY_WORKSPACE_PORTFOLIO,
    variables: { workspaceId },
    fetchPolicy: "network-only",
  });
  return (data?.myWorkspacePortfolio ?? []).map(mapPortfolioItem);
}

/** Portfolio CRUD 成功后失效 myWorkspacePortfolio 根字段缓存。 */
function invalidatePortfolioCache(): void {
  client.cache?.evict({ fieldName: "myWorkspacePortfolio" });
  client.cache?.gc();
}

/**
 * 在某工作台新建作品集条目（ADR-0004；workspace_id 后端自动填充）。
 */
export async function createPortfolioItem(
  workspaceId: string,
  input: CreatePortfolioItemInput,
): Promise<ProfilePortfolioItem> {
  const { data } = await client.mutate({
    mutation: CREATE_PORTFOLIO_ITEM,
    variables: { workspaceId, input },
  });
  const item = data?.createPortfolioItem;
  if (!item) {
    throw new Error("createPortfolioItem failed");
  }
  invalidatePortfolioCache();
  return mapPortfolioItem(item);
}

/**
 * 更新某工作台自己的作品集条目（ADR-0004；tenant 隔离）。
 */
export async function updatePortfolioItem(
  id: string,
  workspaceId: string,
  input: UpdatePortfolioItemInput,
): Promise<ProfilePortfolioItem> {
  const { data } = await client.mutate({
    mutation: UPDATE_PORTFOLIO_ITEM,
    variables: { id, workspaceId, input },
  });
  const item = data?.updatePortfolioItem;
  if (!item) {
    throw new Error("updatePortfolioItem failed");
  }
  invalidatePortfolioCache();
  return mapPortfolioItem(item);
}

/**
 * 删除某工作台自己的作品集条目（ADR-0004；tenant 隔离）。
 */
export async function deletePortfolioItem(
  id: string,
  workspaceId: string,
): Promise<void> {
  const { data } = await client.mutate({
    mutation: DELETE_PORTFOLIO_ITEM,
    variables: { id, workspaceId },
  });
  if (!data?.deletePortfolioItem) {
    throw new Error("deletePortfolioItem failed");
  }
  invalidatePortfolioCache();
}

/** 角色权重（P1-3：无标签=0/基准；learner=2 照旧，纯展示启发式） */
const ROLE_WEIGHT: Record<MembershipRoleName, number> = {
  owner: 6,
  admin: 5,
  tutor: 4,
  volunteer: 3,
  learner: 2,
};

/** 取角色并集里的最高权重（无角色为 0） */
function workspaceRoleWeight(roles: MembershipRoleName[]): number {
  return roles.reduce((max, role) => Math.max(max, ROLE_WEIGHT[role] ?? 0), 0);
}

/**
 * 角色汇总：当前用户所进入 Workspace + 各工作台角色并集。
 * 数据源复用 #63 fetchMyWorkspaces（走 meWorkspaces，用 exists(memberships)
 * 过滤：受邀无 membership 的用户不返回；有 membership 但角色被清空时 myRoleNames=[]）。
 *
 * P1-3（确定性排序规则）：
 * 1. membershipStatus === "active"（已加入）优先于 pending/invited；
 * 2. 再按角色权重降序：owner(6) > admin(5) > tutor(4) > volunteer(3) > learner(2)；无标签=0；
 * 3. Array.prototype.sort 稳定，权重相同时保持后端返回顺序。
 */
export async function fetchProfileRoleSummary(): Promise<ProfileRoleSummary[]> {
  const workspaces = await fetchMyWorkspaces();
  const summaries = workspaces.map((w) => ({
    workspaceId: w.id,
    workspaceSlug: w.slug,
    workspaceName: w.name,
    myRoleNames: w.myRoleNames ?? [],
  }));
  const indexed = workspaces.map((w, i) => ({
    summary: summaries[i],
    status: w.membershipStatus,
  }));
  indexed.sort((a, b) => {
    const statusDelta =
      (b.status === "active" ? 1 : 0) - (a.status === "active" ? 1 : 0);
    if (statusDelta !== 0) return statusDelta;
    return (
      workspaceRoleWeight(b.summary.myRoleNames) -
      workspaceRoleWeight(a.summary.myRoleNames)
    );
  });
  return indexed.map((entry) => entry.summary);
}

/**
 * 按工作区上下文选角色摘要（P1-3）：
 * 优先匹配指定工作区；无上下文或未命中 → 回退排序后第一个持有角色的工作区。
 */
export function pickRoleSummary(
  summaries: ProfileRoleSummary[],
  wsSlug?: string | null,
): ProfileRoleSummary | undefined {
  return (
    (wsSlug ? summaries.find((s) => s.workspaceSlug === wsSlug) : null) ??
    summaries.find((s) => s.myRoleNames.length > 0) ??
    summaries[0]
  );
}

/** 默认社区 workspace slug（ADR-0004：新用户注册自动加入，profile 兜底归属） */
export const DEFAULT_WORKSPACE_SLUG = "2046";

/**
 * 构造个人资料设置链接（ADR-0004：profile 为 per-workspace）。
 * 有 workspace slug → 工作区设置页；无 → 默认社区 workspace 2046 的设置页。
 */
export function profileHref(workspaceSlug?: string | null): string {
  return `/w/${workspaceSlug || DEFAULT_WORKSPACE_SLUG}/settings/account/profile`;
}

/**
 * 资料查看态视图模型（page.tsx 编排层与查看/编辑子组件共享）。
 * 由 me（全局身份）+ workspace profile + 角色 summaries + ws 上下文派生；
 * 字段缺失走空态兜底（不伪造样例）。
 */
export interface ProfileContent {
  name: string;
  location: string;
  about: string;
  skills: string[];
  joinedAt: string;
  visibility: ProfileVisibility;
  memberNumber: string;
  workspaceName: string;
  workspaceSlug: string;
  workspaceRoles: MembershipRoleName[];
  portfolio: ProfilePortfolioItem[];
  avatarUrl: string | null;
}

/** 编辑态表单草稿（ProfileContent 的可编辑子集，空态反向还原）。 */
export interface ProfileDraft {
  name: string;
  location: string;
  about: string;
  skills: string[];
  visibility: ProfileVisibility;
  portfolio: ProfilePortfolioItem[];
  avatarUrl: string | null;
}

/** 资料可见范围三档（2026-08-02 对齐：public / workspace / only_me） */
export const VISIBILITY_LABEL: Record<ProfileVisibility, string> = {
  public: "全站公开",
  workspace: "工作区公开",
  only_me: "仅自己可见",
};

/** 编辑态 select 选项文案（带括号说明） */
export const VISIBILITY_OPTION_LABEL: Record<ProfileVisibility, string> = {
  public: "全站公开（所有登录用户可见）",
  workspace: "工作区公开（同工作区登录用户可见）",
  only_me: "仅自己可见",
};

/** 底部可见范围说明文案 */
export const VISIBILITY_FOOTER_TEXT: Record<ProfileVisibility, string> = {
  public: "资料对全站公开（所有登录用户可见）。",
  workspace: "资料在同工作区公开（同工作区登录用户可见）。",
  only_me: "资料仅自己可见。",
};

/**
 * 组装查看态视图模型。
 * workspace profile（avatar/location/about/skills/visibility）与 me（name/joinedAt/
 * memberNumber）合并；workspaceName/workspaceSlug/workspaceRoles 取 summary 真实回退。
 */
export function getProfileContent(
  me: CurrentProfile,
  wsProfile: WorkspaceProfileContent | null,
  summaries: ProfileRoleSummary[],
  wsSlug?: string | null,
): ProfileContent {
  const summary = pickRoleSummary(summaries, wsSlug);
  const roles = summary?.myRoleNames ?? [];
  return {
    name: me.displayName?.trim() || "未设置展示名",
    location: wsProfile?.location || "未设置",
    about: wsProfile?.about || "暂无简介",
    skills: wsProfile?.skills?.length ? [...wsProfile.skills] : [],
    joinedAt: formatJoinedDate(me.joinedAt),
    visibility: wsProfile?.visibility ?? "only_me",
    memberNumber: me.memberNumber || "—",
    workspaceName: summary?.workspaceName || "",
    workspaceSlug: summary?.workspaceSlug || "",
    workspaceRoles: roles,
    portfolio: [],
    avatarUrl: wsProfile?.avatarUrl ?? null,
  };
}

/** 由查看态视图模型反向构造编辑草稿（空态文案还原为空串）。 */
export function toDraft(content: ProfileContent): ProfileDraft {
  return {
    name: content.name === "未设置展示名" ? "" : content.name,
    location: content.location === "未设置" ? "" : content.location,
    about: content.about === "暂无简介" ? "" : content.about,
    skills: [...content.skills],
    visibility: content.visibility,
    portfolio: content.portfolio.map((item) => ({ ...item })),
    avatarUrl: content.avatarUrl,
  };
}
