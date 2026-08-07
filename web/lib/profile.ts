import type { MembershipRoleName } from "./graphql/workspace";
import type {
  ProfileUser,
  ProfileVisibility,
  UpdateProfileInput,
} from "./graphql/profile";
import { ME_PROFILE, UPDATE_PROFILE } from "./graphql/profile";
import {
  MY_PORTFOLIO,
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
 * #69/#P1 个人资料数据源（#1 能力接口收敛后：唯一真实路径 = GraphQL）。
 *
 * 后端 #68 已定稿（me query + updateProfile mutation）；
 * P1 已扩展（location/about/skills/visibility/memberNumber/joinedAt；
 * PortfolioItem CRUD）。mock 双轨与 USE_MOCK_WORKSPACES 已删除
 * （2026-08-02 决策：本地联调直接跑后端，测试用 fixture 直测纯映射函数）。
 *
 * P1 接入：
 * - fetchCurrentProfile 透传 me 的 P1 扩展字段；
 * - updateCurrentProfile 把 location/about/skills/visibility/avatarUrl
 *   一并提交（修复 G8 Profile 假保存：真实模式下不再只发 displayName 后本地伪造）；
 * - Portfolio CRUD（fetchPortfolioItems / createPortfolioItem /
 *   updatePortfolioItem / deletePortfolioItem）：走 myPortfolio 契约。
 */

export interface CurrentProfile {
  id: string;
  email: string;
  /** 展示名（可编辑字段） */
  displayName?: string | null;
  /** 头像 URL（可空；为空时前端以首字母圆形兜底；data URL / http(s) URL 均可） */
  avatarUrl?: string | null;
  /** 平台管理员 */
  isPlatformAdmin: boolean;
  /** 资料页展示字段；后端未返回时由页面使用设计默认值兜底。 */
  location?: string | null;
  about?: string | null;
  skills?: string[] | null;
  joinedAt?: string | null;
  visibility?: ProfileVisibility | null;
  memberNumber?: string | null;
  workspaceName?: string | null;
  workspaceSlug?: string | null;
  workspaceRoles?: MembershipRoleName[] | null;
  portfolio?: ProfilePortfolioItem[] | null;
}

export type PortfolioIcon = "document" | "book" | "guide";

export interface ProfilePortfolioItem {
  id: string;
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

/** 后端 PortfolioItem（含 userId）→ 前端展示条目（去 userId，icon 兜底 document） */
export function mapPortfolioItem(item: PortfolioItem): ProfilePortfolioItem {
  return {
    id: item.id,
    title: item.title,
    description: item.description ?? "",
    url: item.url ?? null,
    icon: item.icon ?? "document",
  };
}

/**
 * 获取当前用户资料。
 * 唯一真实路径：`me` query（需登录，Bearer token 自动附加），透传 P1 扩展字段。
 *
 * P3 去重：先 `client.readQuery` 读归一化缓存（AuthProvider 的 me 查询与首次
 * 调用已写入 User 实体），命中则零网络返回；miss 才发网络请求。ProfileEntry
 * 在两套壳间切换重新挂载时不再每次触发查询逻辑。clearStore/resetStore 后
 * readQuery 返回 null，自然 fallback 到网络。
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

function mapMeToProfile(me: ProfileUser | null): CurrentProfile {
  if (!me) {
    return {
      id: "",
      email: "",
      displayName: null,
      avatarUrl: null,
      isPlatformAdmin: false,
    };
  }
  return {
    id: me.id,
    email: me.email,
    displayName: me.displayName ?? null,
    avatarUrl: me.avatarUrl ?? null,
    isPlatformAdmin: me.isPlatformAdmin,
    location: me.location ?? null,
    about: me.about ?? null,
    skills: me.skills ?? null,
    visibility: me.visibility ?? null,
    memberNumber: me.memberNumber ?? null,
    joinedAt: me.joinedAt ?? null,
  };
}

/**
 * 更新当前用户资料（P1：提交 displayName/avatarUrl/location/about/skills/visibility，
 * 修复 G8 假保存——不再只发 displayName 后前端伪造扩展字段）。
 */
export async function updateCurrentProfile(
  input: UpdateProfileInput,
): Promise<CurrentProfile> {
  const { data } = await client.mutate({
    mutation: UPDATE_PROFILE,
    variables: { input },
  });
  const me = data?.updateProfile;
  if (!me) {
    return {
      id: "",
      email: "",
      displayName: null,
      avatarUrl: null,
      isPlatformAdmin: false,
    };
  }
  return {
    id: me.id,
    email: me.email,
    displayName: me.displayName ?? null,
    avatarUrl: me.avatarUrl ?? null,
    isPlatformAdmin: me.isPlatformAdmin,
    location: me.location ?? null,
    about: me.about ?? null,
    skills: me.skills ?? null,
    visibility: me.visibility ?? null,
    memberNumber: me.memberNumber ?? null,
    joinedAt: me.joinedAt ?? null,
  };
}

/* ---------------- Portfolio 数据源（P1 真实模式接线） ---------------- */

/**
 * 获取当前用户作品集条目（P1）。
 * 唯一真实路径：myPortfolio query（需登录，Bearer token 自动附加）。
 * P2-3：network-only 保证保存后重新拉取拿到最新列表
 * （默认 cache-first 会命中 CRUD 前的旧缓存，导致保存后即时视图仍显示旧数据/空列表）。
 */
export async function fetchPortfolioItems(): Promise<ProfilePortfolioItem[]> {
  const { data } = await client.query({
    query: MY_PORTFOLIO,
    fetchPolicy: "network-only",
  });
  return (data?.myPortfolio ?? []).map(mapPortfolioItem);
}

/** P2-3：Portfolio CRUD 成功后失效 myPortfolio 根字段缓存，避免其它 cache-first 读取旧数据。 */
function invalidatePortfolioCache(): void {
  client.cache?.evict({ fieldName: "myPortfolio" });
  client.cache?.gc();
}

/**
 * 新建作品集条目（P1）。
 * 唯一真实路径：createPortfolioItem mutation（user_id 后端自动填充）。
 */
export async function createPortfolioItem(
  input: CreatePortfolioItemInput,
): Promise<ProfilePortfolioItem> {
  const { data } = await client.mutate({
    mutation: CREATE_PORTFOLIO_ITEM,
    variables: { input },
  });
  const result = data?.createPortfolioItem;
  if (!result?.result) {
    const msg = result?.errors?.[0]?.message ?? "createPortfolioItem failed";
    throw new Error(msg);
  }
  invalidatePortfolioCache();
  return mapPortfolioItem(result.result);
}

/**
 * 更新自己的作品集条目（P1）。
 * 唯一真实路径：updatePortfolioItem(id, input) mutation。
 */
export async function updatePortfolioItem(
  id: string,
  input: UpdatePortfolioItemInput,
): Promise<ProfilePortfolioItem> {
  const { data } = await client.mutate({
    mutation: UPDATE_PORTFOLIO_ITEM,
    variables: { id, input },
  });
  const result = data?.updatePortfolioItem;
  if (!result?.result) {
    const msg = result?.errors?.[0]?.message ?? "updatePortfolioItem failed";
    throw new Error(msg);
  }
  invalidatePortfolioCache();
  return mapPortfolioItem(result.result);
}

/**
 * 删除自己的作品集条目（P1）。
 * 唯一真实路径：deletePortfolioItem(id) mutation。
 */
export async function deletePortfolioItem(id: string): Promise<void> {
  const { data } = await client.mutate({
    mutation: DELETE_PORTFOLIO_ITEM,
    variables: { id },
  });
  const result = data?.deletePortfolioItem;
  if (!result?.result && result?.errors?.length) {
    const msg = result.errors[0]?.message ?? "deletePortfolioItem failed";
    throw new Error(msg);
  }
  invalidatePortfolioCache();
}

/** 角色权重（P1-3：Profile 绑定 Workspace 上下文的确定性排序依据，纯展示启发式） */
const ROLE_WEIGHT: Record<MembershipRoleName, number> = {
  owner: 6,
  admin: 5,
  tutor: 4,
  volunteer: 3,
  learner: 2,
  member: 1,
};

/** 取角色并集里的最高权重（无角色为 0） */
function workspaceRoleWeight(roles: MembershipRoleName[]): number {
  return roles.reduce((max, role) => Math.max(max, ROLE_WEIGHT[role] ?? 0), 0);
}

/**
 * 角色汇总：当前用户所进入 Workspace + 各工作台角色并集。
 * 数据源复用 #63 fetchMyWorkspaces（走 meWorkspaces，用 exists(memberships)
 * 过滤：受邀无 membership 的用户不返回，故不会出现"受邀未加入"行；
 * 有 membership 但角色被清空（assignRoles 空数组）时 myRoleNames=[]，展示"无角色"）。
 * 展示时仅列当前用户已进入（可访问）的工作台。
 *
 * P1-3（确定性排序规则）：
 * 1. membershipStatus === "active"（已加入）优先于 pending/invited；
 * 2. 再按角色权重降序：owner(6) > admin(5) > tutor(4) > volunteer(3) > learner(2) > member(1)；
 * 3. Array.prototype.sort 稳定，权重相同时保持后端返回顺序。
 * 页面 getProfileContent 取排序后第一个持有角色的工作区（全部无角色时取第一个）
 * 作为默认展示上下文 —— 多 Workspace 用户不再出现"取第一个"的随机性。
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
 * 优先匹配 ?ws= 指定的工作区（从某 workspace 侧栏进入时看该工作区身份）；
 * 无上下文或未命中 → 回退排序后第一个持有角色的工作区（见 fetchProfileRoleSummary
 * 排序：active + 角色权重降序），全部无角色时取首个。
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

/**
 * 构造个人资料设置链接（决策 B：profile 迁入 settings）。
 * 有 workspace slug → 工作区设置页；无 → 全局设置页。
 * 单源供 ProfileEntry 入口复用。
 */
export function profileHref(workspaceSlug?: string | null): string {
  return workspaceSlug
    ? `/w/${workspaceSlug}/settings/account/profile`
    : "/settings/account/profile";
}

/**
 * 资料查看态视图模型（page.tsx 编排层与查看/编辑子组件共享）。
 * 由 profile + 角色 summaries + ws 上下文派生；字段缺失走空态兜底（不伪造样例）。
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
 * 组装查看态视图模型（P1-2 QA 复验 FAIL 修复：渲染兜底不伪造样例）。
 * 字段缺失展示空态（未设置 / 暂无简介 / [] / —）；workspaceName / workspaceSlug
 * 保留 summary 真实回退。多 ws 时取排序后首个持有角色的工作区（见 pickRoleSummary）。
 */
export function getProfileContent(
  profile: CurrentProfile,
  summaries: ProfileRoleSummary[],
  wsSlug?: string | null,
): ProfileContent {
  const summary = pickRoleSummary(summaries, wsSlug);
  const roles = profile.workspaceRoles?.length
    ? profile.workspaceRoles
    : (summary?.myRoleNames ?? []);
  const portfolio = profile.portfolio ?? [];
  return {
    name: profile.displayName?.trim() || "未设置展示名",
    location: profile.location || "未设置",
    about: profile.about || "暂无简介",
    skills: profile.skills?.length ? [...profile.skills] : [],
    joinedAt: formatJoinedDate(profile.joinedAt),
    visibility: profile.visibility ?? "only_me",
    memberNumber: profile.memberNumber || "—",
    workspaceName: profile.workspaceName || summary?.workspaceName || "",
    workspaceSlug: profile.workspaceSlug || summary?.workspaceSlug || "",
    workspaceRoles: roles,
    portfolio: portfolio.map((item) => ({ ...item })),
    avatarUrl: profile.avatarUrl ?? null,
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
