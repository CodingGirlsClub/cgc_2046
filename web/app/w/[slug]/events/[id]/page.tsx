"use client";

/**
 * E-11 #127 活动详情/管理页 /w/[slug]/events/[id]。
 *
 * - 成员可见：元数据 + 报名数据（confirmedCount/capacity，成员读策略完整字段）；
 * - Owner/Admin 可操作：编辑元数据（title/enrollmentPolicy/capacity/
 *   registrationDeadline，含 visibility 双向切换，D9）、launch/close/cancel
 *   状态机动作（allowedTransitions 乐观门控，后端复验）；
 * - 数据唯一真实路径：fetchEvent（GraphQL getEvent）；
 *   加载/草稿状态按 id 键控派生，effect 内不做同步 setState。
 */

import Link from "next/link";
import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	allowedTransitions,
	canManageEvents,
	fetchEvent,
	formatDeadline,
	transitionEvent,
	updateEvent,
} from "@/lib/events";
import type { EventTransition } from "@/lib/events";
import type {
	EnrollmentPolicy,
	EventItem,
	Visibility,
} from "@/lib/graphql/events";
import {
	ENROLLMENT_POLICIES,
	ENROLLMENT_POLICY_LABEL,
	VISIBILITIES,
	VISIBILITY_LABEL,
} from "@/lib/graphql/events";
import WorkspaceShell from "@/components/workspace-shell";
import EventStatusTag from "@/components/event-status-tag";

const TRANSITION_LABEL: Record<EventTransition, string> = {
	launch: "发布（开放报名）",
	close: "结束活动",
	cancel: "取消活动",
};

interface EventState {
	id: string;
	row: EventItem | null;
	error: string | null;
}

interface MetaDraft {
	eventId: string;
	title: string;
	enrollmentPolicy: EnrollmentPolicy;
	capacity: string;
	deadline: string;
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
	return (
		<div>
			<span className="block text-[13px] text-ink-3">{label}</span>
			<span className="mt-0.5 block text-sm text-ink">{children}</span>
		</div>
	);
}

function toLocalInput(datetime: string | null): string {
	if (!datetime) return "";
	const d = new Date(datetime);
	if (Number.isNaN(d.getTime())) return "";
	const pad = (n: number) => String(n).padStart(2, "0");
	return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function fromLocalInput(value: string): string | null {
	if (!value) return null;
	const d = new Date(value);
	return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

export default function WorkspaceEventDetailPage() {
	const params = useParams<{ slug: string; id: string }>();
	const slug = params?.slug ?? "";
	const id = params?.id ?? "";
	const { ws } = useWorkspaceBySlug(slug);
	const [state, setState] = useState<EventState>({ id: "", row: null, error: null });
	const [metaDraft, setMetaDraft] = useState<MetaDraft | null>(null);
	const [saveBusy, setSaveBusy] = useState(false);
	const [saveMessage, setSaveMessage] = useState<string | null>(null);
	const [busyTransition, setBusyTransition] = useState<EventTransition | null>(null);

	useEffect(() => {
		if (!id) return;
		let cancelled = false;

		fetchEvent(id)
			.then((row) => {
				if (!cancelled) setState({ id, row, error: null });
			})
			.catch((e: unknown) => {
				if (!cancelled) {
					setState({
						id,
						row: null,
						error: e instanceof Error ? e.message : "加载失败",
					});
				}
			});

		return () => {
			cancelled = true;
		};
	}, [id]);

	// 派生：id 变化时旧数据/旧草稿不渲染
	const stale = state.id !== id;
	const event = stale ? null : state.row;
	const loadError = stale ? null : state.error;
	const manage = ws ? canManageEvents(ws.myRoleNames) : false;
	const transitions = event ? allowedTransitions(event.status) : [];

	const activeDraft: MetaDraft | null =
		metaDraft && metaDraft.eventId === event?.id
			? metaDraft
			: event
				? {
						eventId: event.id,
						title: event.title,
						enrollmentPolicy: event.enrollmentPolicy,
						capacity: event.capacity === null ? "" : String(event.capacity),
						deadline: toLocalInput(event.registrationDeadline),
					}
				: null;

	async function saveVisibility(next: Visibility) {
		if (!event) return;
		setSaveBusy(true);
		setSaveMessage(null);
		const res = await updateEvent(event.id, { visibility: next });
		setSaveBusy(false);

		if (res.result) {
			setState({ id: event.id, row: { ...event, visibility: res.result.visibility }, error: null });
			setSaveMessage("已保存");
		} else {
			setSaveMessage(res.errors[0]?.message ?? "保存失败");
		}
	}

	async function saveMeta() {
		if (!event || !activeDraft) return;
		setSaveBusy(true);
		setSaveMessage(null);
		const res = await updateEvent(event.id, {
			title: activeDraft.title,
			enrollmentPolicy: activeDraft.enrollmentPolicy,
			capacity: activeDraft.capacity === "" ? null : Number(activeDraft.capacity),
			registrationDeadline: fromLocalInput(activeDraft.deadline),
		});
		setSaveBusy(false);

		if (res.result) {
			setState({
				id: event.id,
				row: {
					...event,
					title: res.result.title,
					enrollmentPolicy: res.result.enrollmentPolicy,
					capacity: res.result.capacity,
					registrationDeadline: res.result.registrationDeadline,
				},
				error: null,
			});
			setMetaDraft(null);
			setSaveMessage("已保存");
		} else {
			setSaveMessage(res.errors[0]?.message ?? "保存失败");
		}
	}

	async function runTransition(t: EventTransition) {
		if (!event) return;
		setBusyTransition(t);
		const res = await transitionEvent(event.id, t);
		setBusyTransition(null);

		if (res.result) {
			setState({ id: event.id, row: { ...event, status: res.result.status }, error: null });
		} else {
			setSaveMessage(res.errors[0]?.message ?? "操作失败");
		}
	}

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/events`}>活动</Link>
					<span>›</span>
					<strong>{event?.title ?? "详情"}</strong>
				</div>

				{loadError ? (
					<div className="rounded-large border border-line bg-card p-6 text-sm text-ink-3">
						加载失败：{loadError}
					</div>
				) : event === null ? (
					<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
				) : (
					<>
						<header className="ws-page-heading">
							<div>
								<h1>{event.title}</h1>
								<p className="flex items-center gap-2">
									<EventStatusTag status={event.status} />
									<span className="text-ink-3">
										{VISIBILITY_LABEL[event.visibility]}
									</span>
								</p>
							</div>
						</header>

						<div className="grid gap-4 sm:grid-cols-2">
							<div className="rounded-large border border-line bg-card p-6">
								<h2 className="text-sm font-medium text-ink">基本信息</h2>
								<div className="mt-4 grid gap-4">
									<Field label="报名策略">
										{ENROLLMENT_POLICY_LABEL[event.enrollmentPolicy]}
									</Field>
									<Field label="报名截止">
										{formatDeadline(event.registrationDeadline)}
									</Field>
									<Field label="名额">
										{event.capacity === null
											? `不限（已确认 ${event.confirmedCount ?? 0}）`
											: `${event.confirmedCount ?? 0} / ${event.capacity}`}
									</Field>
								</div>
							</div>

							{manage && activeDraft ? (
								<div className="rounded-large border border-line bg-card p-6">
									<h2 className="text-sm font-medium text-ink">编辑元数据</h2>

									<div className="mt-4 grid gap-3">
										<label className="block">
											<span className="block text-[13px] text-ink-3">标题</span>
											<input
												value={activeDraft.title}
												onChange={(e) =>
													setMetaDraft({ ...activeDraft, title: e.target.value })
												}
												className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
											/>
										</label>

										<label className="block">
											<span className="block text-[13px] text-ink-3">报名策略</span>
											<select
												value={activeDraft.enrollmentPolicy}
												onChange={(e) =>
													setMetaDraft({
														...activeDraft,
														enrollmentPolicy: e.target.value as EnrollmentPolicy,
													})
												}
												className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
											>
												{ENROLLMENT_POLICIES.map((p) => (
													<option key={p} value={p}>
														{ENROLLMENT_POLICY_LABEL[p]}
													</option>
												))}
											</select>
										</label>

										<label className="block">
											<span className="block text-[13px] text-ink-3">
												名额上限（留空 = 不限）
											</span>
											<input
												type="number"
												min={1}
												value={activeDraft.capacity}
												onChange={(e) =>
													setMetaDraft({ ...activeDraft, capacity: e.target.value })
												}
												className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
											/>
										</label>

										<label className="block">
											<span className="block text-[13px] text-ink-3">
												报名截止（留空 = 不设截止）
											</span>
											<input
												type="datetime-local"
												value={activeDraft.deadline}
												onChange={(e) =>
													setMetaDraft({ ...activeDraft, deadline: e.target.value })
												}
												className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
											/>
										</label>

										<button
											type="button"
											disabled={saveBusy || activeDraft.title.trim() === ""}
											onClick={() => void saveMeta()}
											className="mt-1 rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
										>
											{saveBusy ? "保存中…" : "保存元数据"}
										</button>
									</div>
								</div>
							) : null}
						</div>

						{manage ? (
							<div className="mt-4 rounded-large border border-line bg-card p-6">
								<h2 className="text-sm font-medium text-ink">生命周期</h2>

								<div className="mt-3">
									<span className="block text-[13px] text-ink-3">
										可见性（可随时切换，公开页立即生效）
									</span>
									<div className="mt-2 flex gap-2">
										{VISIBILITIES.map((v) => (
											<button
												key={v}
												type="button"
												disabled={saveBusy || event.visibility === v}
												onClick={() => void saveVisibility(v)}
												className={`rounded-full border px-3 py-1 text-[13px] ${
													event.visibility === v
														? "border-accent bg-soft-2 text-accent"
														: "border-line text-ink-3 hover:border-line-strong"
												}`}
											>
												{VISIBILITY_LABEL[v]}
											</button>
										))}
									</div>
								</div>

								<div className="mt-5 flex flex-wrap gap-2">
									{transitions.map((t) => (
										<button
											key={t}
											type="button"
											disabled={busyTransition !== null}
											onClick={() => void runTransition(t)}
											className="rounded-large border border-line bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line-strong disabled:opacity-50"
										>
											{busyTransition === t ? "处理中…" : TRANSITION_LABEL[t]}
										</button>
									))}
									{transitions.length === 0 ? (
										<span className="text-[13px] text-ink-3">
											终态活动无可执行的生命周期操作（v1 终态不可逆）。
										</span>
									) : null}
								</div>

								{saveMessage ? (
									<p className="mt-3 text-[13px] text-ink-3">{saveMessage}</p>
								) : null}
							</div>
						) : null}
					</>
				)}
			</div>
		</WorkspaceShell>
	);
}
