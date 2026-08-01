import type { MembershipRoleName } from "./graphql/workspace";
import type { UpdateProfileInput } from "./graphql/profile";
import { ME_PROFILE, UPDATE_PROFILE } from "./graphql/profile";
import { client } from "./apollo-client";
import { USE_MOCK_WORKSPACES, fetchMyWorkspaces } from "./workspaces";

/**
 * #69 个人资料数据源。
 *
 * 后端 #68 已定稿（me query + updateProfile mutation，commit 4bd4165）：
 * USE_MOCK_WORKSPACES = false 走真实 GraphQL（fetchCurrentProfile /
 * updateCurrentProfile / fetchProfileRoleSummary），mock 数据保留作兜底
 * （切换 USE_MOCK_WORKSPACES = true 可回到 mock，便于本地无后端联调）。
 * 调用方（app/profile/page.tsx、ProfileEntry 组件）无需改动。
 */

export interface CurrentProfile {
  id: string;
  email: string;
  /** 展示名（可编辑字段；编辑保存后 mock 内存更新） */
  displayName?: string | null;
  /** 头像 URL（可空；为空时前端以首字母圆形兜底） */
  avatarUrl?: string | null;
  /** 平台管理员 */
  isPlatformAdmin: boolean;
  /** 资料页展示字段；#68 API 尚未返回时由页面使用设计默认值兜底。 */
  location?: string | null;
  about?: string | null;
  skills?: string[] | null;
  joinedAt?: string | null;
  visibility?: "workspace_members" | "workspace_public" | null;
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
  visibility: "workspace_members",
  memberNumber: "CGC-SH-0018",
  workspaceName: "上海 Coding Girls Club",
  workspaceSlug: "cgc-shanghai",
  workspaceRoles: ["owner", "tutor"],
  portfolio: MOCK_PROFILE_PORTFOLIO,
};

/**
 * 获取当前用户资料。
 *
 * 后端 #68 已定稿：真实分支走 `me` query（需登录，Bearer token 自动附加）。
 */
export async function fetchCurrentProfile(): Promise<CurrentProfile> {
  if (USE_MOCK_WORKSPACES) {
    return Promise.resolve({ ...MOCK_CURRENT_PROFILE });
  }
  const { data } = await client.query({ query: ME_PROFILE });
  return (
    data?.me ?? {
      id: "",
      email: "",
      displayName: null,
      avatarUrl: null,
      isPlatformAdmin: false,
    }
  );
}

/**
 * 更新当前用户资料（mock：内存更新 MOCK_CURRENT_PROFILE，成功后重新 fetch 拿到新值）。
 * 真实：调用后端 updateProfile mutation（#68 定稿：input.displayName 必填，avatarUrl 可选）。
 */
export async function updateCurrentProfile(
  input: UpdateProfileInput,
): Promise<CurrentProfile> {
  if (USE_MOCK_WORKSPACES) {
    if (typeof input.displayName === "string" && input.displayName.trim() !== "") {
      MOCK_CURRENT_PROFILE.displayName = input.displayName;
    }
    return Promise.resolve({ ...MOCK_CURRENT_PROFILE });
  }
  const { data } = await client.mutate({
    mutation: UPDATE_PROFILE,
    variables: { input },
  });
  return (
    data?.updateProfile ?? {
      id: "",
      email: "",
      displayName: null,
      avatarUrl: null,
      isPlatformAdmin: false,
    }
  );
}

/**
 * 角色汇总：当前用户所进入 Workspace + 各工作台角色并集。
 * 数据源复用 #63 fetchMyWorkspaces（真实分支走后端 meWorkspaces，
 * 用 exists(memberships) 过滤：受邀无 membership 的用户不返回，
 * 故真实数据下角色汇总不会出现"受邀未加入"行；有 membership 但角色
 * 被清空（assignRoles 空数组）时 myRoleNames=[]，展示"无角色"）。
 * 展示时仅列当前用户已进入（可访问）的工作台。
 */
export async function fetchProfileRoleSummary(): Promise<ProfileRoleSummary[]> {
  const workspaces = await fetchMyWorkspaces();
  return workspaces.map((w) => ({
    workspaceId: w.id,
    workspaceSlug: w.slug,
    workspaceName: w.name,
    myRoleNames: w.myRoleNames ?? [],
  }));
}
