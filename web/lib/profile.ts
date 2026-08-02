import type { MembershipRoleName } from "./graphql/workspace";
import type { ProfileVisibility, UpdateProfileInput } from "./graphql/profile";
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
import { USE_MOCK_WORKSPACES, fetchMyWorkspaces } from "./workspaces";

/**
 * #69/#P1 个人资料数据源。
 *
 * 后端 #68 已定稿（me query + updateProfile mutation，commit 4bd4165）；
 * P1 已扩展（bd22063：location/about/skills/visibility/memberNumber/joinedAt；
 * 56b5ce2：PortfolioItem CRUD）。
 * USE_MOCK_WORKSPACES = false 走真实 GraphQL，mock 数据保留作兜底
 * （切换 USE_MOCK_WORKSPACES = true 可回到 mock，便于本地无后端联调）。
 *
 * P1 接入：
 * - fetchCurrentProfile 真实分支透传 me 的 P1 扩展字段；
 * - updateCurrentProfile 真实分支把 location/about/skills/visibility/avatarUrl
 *   一并提交（修复 G8 Profile 假保存：真实模式下不再只发 displayName 后本地伪造）；
 * - Portfolio CRUD（fetchPortfolioItems / createPortfolioItem /
 *   updatePortfolioItem / deletePortfolioItem）：真实分支走 myPortfolio 契约，
 *   mock 分支操作内存 MOCK_PROFILE_PORTFOLIO。
 */

export interface CurrentProfile {
  id: string;
  email: string;
  /** 展示名（可编辑字段；编辑保存后 mock 内存更新） */
  displayName?: string | null;
  /** 头像 URL（可空；为空时前端以首字母圆形兜底；data URL / http(s) URL 均可） */
  avatarUrl?: string | null;
  /** 平台管理员 */
  isPlatformAdmin: boolean;
  /** 资料页展示字段；#68 API 尚未返回时由页面使用设计默认值兜底。 */
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

/** 设计稿展示的可扩展作品集示例；首页只预览前三条，其余通过全量入口承载。 */
export const MOCK_PROFILE_PORTFOLIO: ProfilePortfolioItem[] = [
  {
    id: "portfolio-ai-course",
    title: "AI 入门工作坊课程大纲",
    description: "一套面向零基础学习者的 6 周课程设计。",
    url: "https://example.com/ai-course",
    icon: "document",
  },
  {
    id: "portfolio-mentor-guide",
    title: "社区导师手册",
    description: "导师协作原则、答疑流程与课堂支持清单。",
    url: "https://example.com/mentor-guide",
    icon: "book",
  },
  {
    id: "portfolio-openclacky-guide",
    title: "OpenClacky 入门指南",
    description: "从安装到连接 CGC 的完整上手指引。",
    url: "https://example.com/openclacky-guide",
    icon: "guide",
  },
  {
    id: "portfolio-course-retro",
    title: "课程复盘：从 0 到 1",
    description: "把第一次教研实践整理成可复用的复盘模板。",
    url: "https://example.com/course-retro",
    icon: "document",
  },
  {
    id: "portfolio-ai-reading",
    title: "AI 教育阅读清单",
    description: "面向社区学习者的精选阅读与讨论问题。",
    url: "https://example.com/ai-reading",
    icon: "book",
  },
  {
    id: "portfolio-community-kit",
    title: "社区活动工具包",
    description: "从招募到复盘的一站式活动运营清单。",
    url: "https://example.com/community-kit",
    icon: "guide",
  },
  {
    id: "portfolio-elixir-notes",
    title: "Elixir 学习笔记",
    description: "用小项目串起 OTP 与 Phoenix 的入门路径。",
    url: "https://example.com/elixir-notes",
    icon: "document",
  },
  {
    id: "portfolio-tutor-workshop",
    title: "导师工作坊设计",
    description: "帮助新导师完成第一次共备与授课。",
    url: "https://example.com/tutor-workshop",
    icon: "book",
  },
  {
    id: "portfolio-accessibility",
    title: "无障碍课程检查表",
    description: "把课堂内容与协作工具的可访问性纳入流程。",
    url: "https://example.com/accessibility",
    icon: "guide",
  },
  {
    id: "portfolio-cgc-playbook",
    title: "CGC 社区协作 playbook",
    description: "记录跨角色协作、反馈与知识沉淀的实践。",
    url: "https://example.com/cgc-playbook",
    icon: "document",
  },
];

/** 角色汇总条目：当前用户在某个可进入 Workspace 的角色并集 */
export interface ProfileRoleSummary {
  workspaceId: string;
  workspaceSlug: string;
  workspaceName: string;
  /** 当前用户在该工作台的角色名数组（非成员/受邀未加入为 []） */
  myRoleNames: MembershipRoleName[];
}

/** mock：当前登录用户（与 #63 mock 工作台 myRoleNames 语义一致） */
export const MOCK_CURRENT_PROFILE: CurrentProfile = {
  id: "u_0202",
  email: "xiaomei@example.com",
  displayName: "小美",
  avatarUrl: null,
  isPlatformAdmin: false,
  location: "上海",
  about: "关注社区学习、AI 教育与开放协作。喜欢把复杂的问题整理成清晰、可执行的课程与活动。",
  skills: ["AI 教育", "课程设计", "社区运营", "Elixir"],
  joinedAt: "2024 年 3 月",
  visibility: "only_me",
  memberNumber: "CGC-SH-0018",
  workspaceName: "上海 Coding Girls Club",
  workspaceSlug: "cgc-shanghai",
  // 角色值引用 lib/graphql/workspace.ts 的 ROLE_NAMES 单源语义（此处为 mock 数据值，子集）
  workspaceRoles: ["owner", "tutor"],
  portfolio: MOCK_PROFILE_PORTFOLIO,
};

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
 *
 * 后端 #68/#P1 已定稿：真实分支走 `me` query（需登录，Bearer token 自动附加），
 * 透传 P1 扩展字段（location/about/skills/visibility/memberNumber/joinedAt）。
 */
export async function fetchCurrentProfile(): Promise<CurrentProfile> {
  if (USE_MOCK_WORKSPACES) {
    return Promise.resolve({ ...MOCK_CURRENT_PROFILE });
  }
  const { data } = await client.query({ query: ME_PROFILE });
  const me = data?.me;
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
 * 更新当前用户资料（P1：真实分支提交 displayName/avatarUrl/location/about/skills/visibility，
 * 修复 G8 假保存——不再只发 displayName 后前端伪造扩展字段）。
 * mock：内存更新 MOCK_CURRENT_PROFILE，成功后重新 fetch 拿到新值。
 */
export async function updateCurrentProfile(
  input: UpdateProfileInput,
): Promise<CurrentProfile> {
  if (USE_MOCK_WORKSPACES) {
    if (typeof input.displayName === "string" && input.displayName.trim() !== "") {
      MOCK_CURRENT_PROFILE.displayName = input.displayName;
    }
    if (input.avatarUrl !== undefined) MOCK_CURRENT_PROFILE.avatarUrl = input.avatarUrl;
    if (input.location !== undefined) MOCK_CURRENT_PROFILE.location = input.location;
    if (input.about !== undefined) MOCK_CURRENT_PROFILE.about = input.about;
    if (input.skills !== undefined) MOCK_CURRENT_PROFILE.skills = input.skills;
    if (input.visibility !== undefined) MOCK_CURRENT_PROFILE.visibility = input.visibility;
    return Promise.resolve({ ...MOCK_CURRENT_PROFILE });
  }
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
 * mock：返回设计稿演示数据 MOCK_PROFILE_PORTFOLIO；
 * 真实：走 myPortfolio query（需登录，Bearer token 自动附加）。
 */
export async function fetchPortfolioItems(): Promise<ProfilePortfolioItem[]> {
  if (USE_MOCK_WORKSPACES) {
    return Promise.resolve(MOCK_PROFILE_PORTFOLIO.map((item) => ({ ...item })));
  }
  // P2-3：network-only 保证保存后重新拉取拿到最新列表
  // （默认 cache-first 会命中 CRUD 前的旧缓存，导致保存后即时视图仍显示旧数据/空列表）。
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
 * mock：内存追加 MOCK_PROFILE_PORTFOLIO（本地生成 uuid 风格 id）；
 * 真实：createPortfolioItem mutation（user_id 后端自动填充）。
 */
export async function createPortfolioItem(
  input: CreatePortfolioItemInput,
): Promise<ProfilePortfolioItem> {
  if (USE_MOCK_WORKSPACES) {
    const item: ProfilePortfolioItem = {
      id: `portfolio-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      title: input.title,
      description: input.description ?? "",
      url: input.url ?? null,
      icon: input.icon ?? "document",
    };
    MOCK_PROFILE_PORTFOLIO.push(item);
    return Promise.resolve({ ...item });
  }
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
 * mock：内存替换 MOCK_PROFILE_PORTFOLIO 中对应条目；
 * 真实：updatePortfolioItem(id, input) mutation。
 */
export async function updatePortfolioItem(
  id: string,
  input: UpdatePortfolioItemInput,
): Promise<ProfilePortfolioItem> {
  if (USE_MOCK_WORKSPACES) {
    const idx = MOCK_PROFILE_PORTFOLIO.findIndex((item) => item.id === id);
    if (idx === -1) throw new Error(`portfolio item not found: ${id}`);
    const updated: ProfilePortfolioItem = {
      ...MOCK_PROFILE_PORTFOLIO[idx],
      ...(input.title !== undefined && input.title !== null ? { title: input.title } : {}),
      ...(input.description !== undefined ? { description: input.description ?? "" } : {}),
      ...(input.url !== undefined ? { url: input.url ?? null } : {}),
      ...(input.icon !== undefined ? { icon: input.icon ?? "document" } : {}),
    };
    MOCK_PROFILE_PORTFOLIO[idx] = updated;
    return Promise.resolve({ ...updated });
  }
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
 * mock：内存移除 MOCK_PROFILE_PORTFOLIO 中对应条目；
 * 真实：deletePortfolioItem(id) mutation。
 */
export async function deletePortfolioItem(id: string): Promise<void> {
  if (USE_MOCK_WORKSPACES) {
    const idx = MOCK_PROFILE_PORTFOLIO.findIndex((item) => item.id === id);
    if (idx !== -1) MOCK_PROFILE_PORTFOLIO.splice(idx, 1);
    return Promise.resolve();
  }
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

/** 角色权重（P1-3：Profile 绑定 Workspace 上下文的确定性排序依据） */
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
 * 数据源复用 #63 fetchMyWorkspaces（真实分支走后端 meWorkspaces，
 * 用 exists(memberships) 过滤：受邀无 membership 的用户不返回，
 * 故真实数据下角色汇总不会出现"受邀未加入"行；有 membership 但角色
 * 被清空（assignRoles 空数组）时 myRoleNames=[]，展示"无角色"）。
 * 展示时仅列当前用户已进入（可访问）的工作台。
 *
 * P1-3（确定性排序规则，真实分支）：
 * 1. membershipStatus === "active"（已加入）优先于 pending/invited；
 * 2. 再按角色权重降序：owner(6) > admin(5) > tutor(4) > volunteer(3) > learner(2) > member(1)；
 * 3. Array.prototype.sort 稳定，权重相同时保持后端返回顺序。
 * 页面 getProfileContent 取排序后第一个持有角色的工作区（全部无角色时取第一个）
 * 作为默认展示上下文 —— 多 Workspace 用户不再出现"取第一个"的随机性。
 * mock 模式保持现状（不排序，维持原展示顺序）。
 */
export async function fetchProfileRoleSummary(): Promise<ProfileRoleSummary[]> {
  const workspaces = await fetchMyWorkspaces();
  const summaries = workspaces.map((w) => ({
    workspaceId: w.id,
    workspaceSlug: w.slug,
    workspaceName: w.name,
    myRoleNames: w.myRoleNames ?? [],
  }));
  if (!USE_MOCK_WORKSPACES) {
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
  return summaries;
}
