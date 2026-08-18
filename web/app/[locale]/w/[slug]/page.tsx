"use client";

/**
 * #74 工作区概览页 /w/[slug]。
 *
 * #63 占位页已被本页取代：接入 WorkspaceShell（壳负责未认证重定向、侧栏、
 * 退出登录与「工作区不可访问」态），页面退化为壳内纯内容 —— Hero / 信息卡
 * 网格 / 管理入口。
 *
 * 数据：只消费真实数据（useWorkspaceBySlug → fetchMyWorkspaces 唯一路径，
 * #1 mock 双轨已删除，2026-08-02 决策）；未解析完成时渲染骨架，绝不渲染
 * 假数据。未知 slug 的「工作区不可访问」由壳 requireWs 渲染，页面不处理。
 */

import Link from "next/link";
import { useParams } from "next/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { currentUserCanAssignRoles } from "@/lib/workspaces";
import { JOIN_POLICY_HINT, JOIN_POLICY_LABEL } from "@/lib/graphql/workspace";
import WorkspaceShell from "@/components/workspace-shell";
import { Icon } from "@/components/icons";
import {
	getWorkspaceRoles,
	InfoCard,
	RoleChips,
	StatusTag,
	WorkspaceAvatar,
} from "@/components/workspace-ui";

export default function WorkspacePage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>概览</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>工作区概览</h1>
						<p>工作区的入口信息与常用管理入口</p>
					</div>
				</header>

				{wsLoading ? (
					<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
				) : ws ? (
					<>
						{/* Hero：头像 / 名称 / slug / Active / 角色 chips / 加入方式（对标首页 workspace-detail-hero） */}
						<div className="workspace-detail-hero">
							<WorkspaceAvatar ws={ws} large />
							<div className="workspace-detail-hero__body">
								<h2>{ws.name}</h2>
								<p className="workspace-slug">{ws.slug}</p>
								<div className="workspace-detail-hero__meta">
									<StatusTag status="active" />
									<RoleChips roles={getWorkspaceRoles(ws)} />
								</div>
							</div>
							<div className="workspace-detail-hero__policy">
								<span>加入方式</span>
								<strong
									className={`workspace-policy workspace-policy--${ws.joinPolicy}`}
								>
									{JOIN_POLICY_LABEL[ws.joinPolicy]}
								</strong>
								<p>{JOIN_POLICY_HINT[ws.joinPolicy]}</p>
							</div>
						</div>

						{/* 信息卡网格：加入方式 / 我的角色 / 社区规模 */}
						<div className="workspace-info-grid">
							<InfoCard icon="community" title="加入方式">
								<strong className="workspace-info-card__value">
									{JOIN_POLICY_LABEL[ws.joinPolicy]}
								</strong>
								<p>{JOIN_POLICY_HINT[ws.joinPolicy]}</p>
							</InfoCard>
							<InfoCard icon="role" title="我的角色">
								<RoleChips roles={getWorkspaceRoles(ws)} />
								<p>权限按当前角色并集计算</p>
							</InfoCard>
							<InfoCard icon="members" title="社区规模">
								<strong
									className="workspace-info-card__value"
									data-testid="workspace-member-count"
								>
									{ws.memberCount != null ? `${ws.memberCount} 位成员` : "—"}
								</strong>
								<p>{ws.sponsorshipEnabled ? "已开放赞助" : "暂未开放赞助"}</p>
							</InfoCard>
						</div>

						{/* 管理入口：成员与角色（canAssign 门控文案）/ 权限映射 */}
						<div className="mt-6 grid gap-4 sm:grid-cols-2">
							<Link
								href={`/w/${slug}/settings/members`}
								className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
							>
								<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
									<Icon name="users" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block text-sm font-medium text-ink">
										成员与角色
									</span>
									<span className="mt-1 block text-[13px] leading-5 text-ink-3">
										{currentUserCanAssignRoles(ws)
											? "管理成员列表与角色分配"
											: "查看成员列表与自己的角色"}
									</span>
								</span>
								<span className="flex-none text-ink-3">
									<Icon name="arrow" />
								</span>
							</Link>
							<Link
								href={`/w/${slug}/settings/permissions`}
								className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
							>
								<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
									<Icon name="shield" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block text-sm font-medium text-ink">
										权限映射
									</span>
									<span className="mt-1 block text-[13px] leading-5 text-ink-3">
										查看角色 → 能力矩阵
									</span>
								</span>
								<span className="flex-none text-ink-3">
									<Icon name="arrow" />
								</span>
							</Link>
						</div>

						{/* 教研产出入口（切片 C 已落地，见 workflows 页；plan 016 替换过期占位卡）。
						    报名/赞助（切片 E）仍为占位：视觉降级虚线边框 + 「即将开放」角标 */}
						<div className="mt-4 grid gap-4 sm:grid-cols-2">
							{/* plan 020 U1：Agents 与助手协作引导卡 → /w/[slug]/agents */}
							<Link
								href={`/w/${slug}/agents`}
								className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
							>
								<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
									<Icon name="activity" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block text-sm font-medium text-ink">
										Agents 与助手协作
									</span>
									<span className="mt-1 block text-[13px] leading-5 text-ink-3">
										查看助手活动与待办交接
									</span>
								</span>
								<span className="flex-none text-ink-3">
									<Icon name="arrow" />
								</span>
							</Link>
							<Link
								href={`/w/${slug}/workflows`}
								className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
							>
								<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
									<Icon name="book" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block text-sm font-medium text-ink">
										Workflow 产出
									</span>
									<span className="mt-1 block text-[13px] leading-5 text-ink-3">
										查看教研产出与工作流结果
									</span>
								</span>
								<span className="flex-none text-ink-3">
									<Icon name="arrow" />
								</span>
							</Link>
							<Link
								href={`/w/${slug}/events`}
								className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
							>
								<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
									<Icon name="book" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block text-sm font-medium text-ink">活动</span>
									<span className="mt-1 block text-[13px] leading-5 text-ink-3">
										浏览工作台活动与报名信息
									</span>
								</span>
								<span className="flex-none text-ink-3">
									<Icon name="arrow" />
								</span>
							</Link>
							<Link
								href={`/w/${slug}/courses`}
								className="flex items-center gap-4 rounded-large border border-line bg-card p-6"
							>
								<span className="flex h-12 w-12 flex-none items-center justify-center rounded-full border border-line-strong bg-soft-2 text-accent">
									<Icon name="book" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block text-sm font-medium text-ink">课程</span>
									<span className="mt-1 block text-[13px] leading-5 text-ink-3">
										浏览工作台课程与报名信息
									</span>
								</span>
								<span className="flex-none text-ink-3">
									<Icon name="arrow" />
								</span>
							</Link>
						</div>
					</>
				) : null}
			</div>
		</WorkspaceShell>
	);
}
