"use client";

/**
 * E-11 #127 活动列表页 /w/[slug]/events。
 *
 * - 成员可见本工作台全部活动（draft/open/closed/cancelled 全生命周期，
 *   读策略成员可读）；非成员/未知 slug 由 WorkspaceShell 兜底；
 * - Owner/Admin（MANAGE_ROLE_NAMES 交集）另见「新建活动」与管理入口
 *   （后端 policy 兜底，前端门控仅为展示）；
 * - 数据唯一真实路径：fetchWorkspaceEvents（GraphQL listEvents）；
 *   未解析完成渲染骨架，绝不渲染假数据（同 useWorkspaceBySlug 纪律）。
 *   加载状态走派生判定（wsId 键控），effect 内不做同步 setState。
 */

import Link from "next/link";
import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	canManageEvents,
	fetchWorkspaceEvents,
	formatDeadline,
} from "@/lib/events";
import type { EventItem } from "@/lib/graphql/events";
import {
	ENROLLMENT_POLICY_LABEL,
	VISIBILITY_LABEL,
} from "@/lib/graphql/events";
import WorkspaceShell from "@/components/workspace-shell";
import { Icon } from "@/components/icons";
import EventStatusTag from "@/components/event-status-tag";

interface EventsState {
	wsId: string;
	rows: EventItem[] | null;
	error: string | null;
}

function EventRow({ event, slug }: { event: EventItem; slug: string }) {
	return (
		<Link
			href={`/w/${slug}/events/${event.id}`}
			className="flex items-center gap-4 rounded-large border border-line bg-card p-5 transition-colors hover:border-line-strong"
		>
			<span className="min-w-0 flex-1">
				<span className="flex items-center gap-2">
					<span className="block truncate text-sm font-medium text-ink">
						{event.title}
					</span>
					<EventStatusTag status={event.status} />
				</span>
				<span className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[13px] leading-5 text-ink-3">
					<span>{ENROLLMENT_POLICY_LABEL[event.enrollmentPolicy]}</span>
					<span>·</span>
					<span>{VISIBILITY_LABEL[event.visibility]}</span>
					<span>·</span>
					<span>截止 {formatDeadline(event.registrationDeadline)}</span>
				</span>
			</span>
			<span className="flex-none text-ink-3">
				<Icon name="arrow" />
			</span>
		</Link>
	);
}

export default function WorkspaceEventsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);
	const [state, setState] = useState<EventsState>({ wsId: "", rows: null, error: null });

	useEffect(() => {
		if (!ws) return;

		let cancelled = false;

		fetchWorkspaceEvents(ws.id)
			.then((rows) => {
				if (!cancelled) setState({ wsId: ws.id, rows, error: null });
			})
			.catch((e: unknown) => {
				if (!cancelled) {
					setState({
						wsId: ws.id,
						rows: null,
						error: e instanceof Error ? e.message : "加载失败",
					});
				}
			});

		return () => {
			cancelled = true;
		};
	}, [ws]);

	// 派生加载态：ws 变化（或未解析）时保持骨架，不渲染过期数据
	const stale = ws ? state.wsId !== ws.id : false;
	const events = stale ? null : state.rows;
	const loadError = stale ? null : state.error;
	const manage = ws ? canManageEvents(ws.myRoleNames) : false;

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>活动</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>活动</h1>
						<p>本工作台的全部活动：草稿、开放报名与已结束</p>
					</div>
					{manage && ws ? (
						<Link
							href={`/w/${slug}/events/new`}
							className="inline-flex items-center gap-2 rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink"
						>
							<Icon name="plus" />
							新建活动
						</Link>
					) : null}
				</header>

				{wsLoading || events === null ? (
					<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
				) : loadError ? (
					<div className="rounded-large border border-line bg-card p-6 text-sm text-ink-3">
						加载失败：{loadError}
					</div>
				) : events.length === 0 ? (
					<div className="rounded-large border border-dashed border-line bg-card p-10 text-center text-sm text-ink-3">
						还没有活动。
						{manage ? "点击右上角「新建活动」创建第一个。" : "等待 Owner 创建。"}
					</div>
				) : (
					<div className="grid gap-3">
						{events.map((event) => (
							<EventRow key={event.id} event={event} slug={slug} />
						))}
					</div>
				)}
			</div>
		</WorkspaceShell>
	);
}
