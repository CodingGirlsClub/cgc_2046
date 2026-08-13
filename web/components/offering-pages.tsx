"use client";

/**
 * E-11 #127 活动/课程共享页面组件（kind 参数化；events 与 courses 薄壳复用）。
 *
 * - 成员可见：本工作台全部 offering（draft/open/closed/cancelled 全生命周期）；
 * - Owner/Admin 可操作：新建、元数据编辑（含 visibility 双向切换，D9）、
 *   launch/close/cancel（allowedTransitions 乐观门控，后端复验）；
 * - 数据唯一真实路径：fetchWorkspaceOfferings/fetchOffering（GraphQL）；
 *   加载/草稿状态按 wsId/id 键控派生，effect 内不做同步 setState。
 */

import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import {
	allowedTransitions,
	canManageEvents,
	createOffering,
	fetchOffering,
	fetchPendingCount,
	fetchWorkspaceOfferings,
	formatDeadline,
	transitionOffering,
	updateOffering,
} from "@/lib/events";
import type { EventTransition } from "@/lib/events";
import type {
	EnrollmentPolicy,
	OfferingItem,
	OfferingKind,
	Visibility,
} from "@/lib/graphql/events";
import {
	ENROLLMENT_POLICIES,
	ENROLLMENT_POLICY_LABEL,
	OFFERING_LABEL,
	VISIBILITIES,
	VISIBILITY_LABEL,
} from "@/lib/graphql/events";
import WorkspaceShell from "@/components/workspace-shell";
import EventStatusTag from "@/components/event-status-tag";
import { Icon } from "@/components/icons";

const TRANSITION_LABEL: Record<EventTransition, string> = {
	launch: "发布（开放报名）",
	close: "结束",
	cancel: "取消",
};

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

function Field({ label, children }: { label: string; children: React.ReactNode }) {
	return (
		<div>
			<span className="block text-[13px] text-ink-3">{label}</span>
			<span className="mt-0.5 block text-sm text-ink">{children}</span>
		</div>
	);
}

/* ---------------- 列表页 ---------------- */

interface OfferingsState {
	wsId: string;
	rows: OfferingItem[] | null;
	error: string | null;
}

function OfferingRow({
	offering,
	slug,
	kind,
}: {
	offering: OfferingItem;
	slug: string;
	kind: OfferingKind;
}) {
	const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;
	return (
		<Link
			href={`${base}/${offering.id}`}
			className="flex items-center gap-4 rounded-large border border-line bg-card p-5 transition-colors hover:border-line-strong"
		>
			<span className="min-w-0 flex-1">
				<span className="flex items-center gap-2">
					<span className="block truncate text-sm font-medium text-ink">
						{offering.title}
					</span>
					<EventStatusTag status={offering.status} />
				</span>
				<span className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[13px] leading-5 text-ink-3">
					<span>{ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy]}</span>
					<span>·</span>
					<span>{VISIBILITY_LABEL[offering.visibility]}</span>
					<span>·</span>
					<span>截止 {formatDeadline(offering.registrationDeadline)}</span>
				</span>
			</span>
			<span className="flex-none text-ink-3">
				<Icon name="arrow" />
			</span>
		</Link>
	);
}

export function OfferingsListPage({ slug, kind }: { slug: string; kind: OfferingKind }) {
	const { ws, loading: wsLoading } = useWorkspaceBySlugWrapper(slug);
	const [state, setState] = useState<OfferingsState>({ wsId: "", rows: null, error: null });

	useEffect(() => {
		if (!ws) return;

		let cancelled = false;

		fetchWorkspaceOfferings(ws.id, kind)
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
	}, [ws, kind]);

	const stale = ws ? state.wsId !== ws.id : false;
	const rows = stale ? null : state.rows;
	const loadError = stale ? null : state.error;
	const manage = ws ? canManageEvents(ws.myRoleNames) : false;
	const label = OFFERING_LABEL[kind];
	const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>{label}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{label}</h1>
						<p>本工作台的全部{label}：草稿、开放报名与已结束</p>
					</div>
					{manage && ws ? (
						<Link
							href={`${base}/new`}
							className="inline-flex items-center gap-2 rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink"
						>
							<Icon name="plus" />
							新建{label}
						</Link>
					) : null}
				</header>

				{loadError ? (
					<div className="rounded-large border border-line bg-card p-6 text-sm text-ink-3">
						加载失败：{loadError}
					</div>
				) : wsLoading || rows === null ? (
					<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
				) : rows.length === 0 ? (
					<div className="rounded-large border border-dashed border-line bg-card p-10 text-center text-sm text-ink-3">
						还没有{label}。
						{manage ? `点击右上角「新建${label}」创建第一个。` : "等待 Owner 创建。"}
					</div>
				) : (
					<div className="grid gap-3">
						{rows.map((offering) => (
							<OfferingRow key={offering.id} offering={offering} slug={slug} kind={kind} />
						))}
					</div>
				)}
			</div>
		</WorkspaceShell>
	);
}

/* ---------------- 详情/管理页 ---------------- */

interface OfferingState {
	id: string;
	row: OfferingItem | null;
	error: string | null;
}

interface MetaDraft {
	offeringId: string;
	title: string;
	enrollmentPolicy: EnrollmentPolicy;
	capacity: string;
	deadline: string;
}

export function OfferingDetailPage({
	slug,
	id,
	kind,
}: {
	slug: string;
	id: string;
	kind: OfferingKind;
}) {
	const { ws } = useWorkspaceBySlugWrapper(slug);
	const [state, setState] = useState<OfferingState>({ id: "", row: null, error: null });
	const [metaDraft, setMetaDraft] = useState<MetaDraft | null>(null);
	const [saveBusy, setSaveBusy] = useState(false);
	const [saveMessage, setSaveMessage] = useState<string | null>(null);
	const [busyTransition, setBusyTransition] = useState<EventTransition | null>(null);
	const [pendingCount, setPendingCount] = useState<number | null>(null);

	useEffect(() => {
		if (!id) return;
		let cancelled = false;

		fetchOffering(id, kind)
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
	}, [id, kind]);

	// pending 报名数（报名数据视图：request 策略待审批）
	useEffect(() => {
		if (!id) return;
		let cancelled = false;

		fetchPendingCount(id, kind)
			.then((n) => {
				if (!cancelled) setPendingCount(n);
			})
			.catch(() => {
				if (!cancelled) setPendingCount(0);
			});

		return () => {
			cancelled = true;
		};
	}, [id, kind]);

	const stale = state.id !== id;
	const offering = stale ? null : state.row;
	const loadError = stale ? null : state.error;
	const manage = ws ? canManageEvents(ws.myRoleNames) : false;
	const transitions = offering ? allowedTransitions(offering.status) : [];
	const label = OFFERING_LABEL[kind];
	const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;

	const activeDraft: MetaDraft | null =
		metaDraft && metaDraft.offeringId === offering?.id
			? metaDraft
			: offering
				? {
						offeringId: offering.id,
						title: offering.title,
						enrollmentPolicy: offering.enrollmentPolicy,
						capacity: offering.capacity === null ? "" : String(offering.capacity),
						deadline: toLocalInput(offering.registrationDeadline),
					}
				: null;

	async function saveVisibility(next: Visibility) {
		if (!offering) return;
		setSaveBusy(true);
		setSaveMessage(null);
		try {
			const res = await updateOffering(offering.id, kind, { visibility: next });
			if (res.result) {
				setState({
					id: offering.id,
					row: { ...offering, visibility: res.result.visibility },
					error: null,
				});
				setSaveMessage("已保存");
			} else {
				setSaveMessage(res.errors[0]?.message ?? "保存失败");
			}
		} catch (e: unknown) {
			setSaveMessage(e instanceof Error ? e.message : "保存失败");
		} finally {
			setSaveBusy(false);
		}
	}

	async function saveMeta() {
		if (!offering || !activeDraft) return;
		setSaveBusy(true);
		setSaveMessage(null);
		try {
			const res = await updateOffering(offering.id, kind, {
				title: activeDraft.title,
				enrollmentPolicy: activeDraft.enrollmentPolicy,
				capacity: activeDraft.capacity === "" ? null : Number(activeDraft.capacity),
				registrationDeadline: fromLocalInput(activeDraft.deadline),
			});
			if (res.result) {
				setState({
					id: offering.id,
					row: {
						...offering,
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
		} catch (e: unknown) {
			setSaveMessage(e instanceof Error ? e.message : "保存失败");
		} finally {
			setSaveBusy(false);
		}
	}

	async function runTransition(t: EventTransition) {
		if (!offering) return;
		setBusyTransition(t);
		try {
			const res = await transitionOffering(offering.id, kind, t);
			if (res.result) {
				setState({ id: offering.id, row: { ...offering, status: res.result.status }, error: null });
			} else {
				setSaveMessage(res.errors[0]?.message ?? "操作失败");
			}
		} catch (e: unknown) {
			setSaveMessage(e instanceof Error ? e.message : "操作失败");
		} finally {
			setBusyTransition(null);
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
					<Link href={base}>{label}</Link>
					<span>›</span>
					<strong>{offering?.title ?? "详情"}</strong>
				</div>

				{loadError ? (
					<div className="rounded-large border border-line bg-card p-6 text-sm text-ink-3">
						加载失败：{loadError}
					</div>
				) : offering === null ? (
					<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
				) : (
					<>
						<header className="ws-page-heading">
							<div>
								<h1>{offering.title}</h1>
								<p className="flex items-center gap-2">
									<EventStatusTag status={offering.status} />
									<span className="text-ink-3">
										{VISIBILITY_LABEL[offering.visibility]}
									</span>
								</p>
							</div>
						</header>

						<div className="grid gap-4 sm:grid-cols-2">
							<div className="rounded-large border border-line bg-card p-6">
								<h2 className="text-sm font-medium text-ink">基本信息</h2>
								<div className="mt-4 grid gap-4">
									<Field label="报名策略">
										{ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy]}
									</Field>
									<Field label="报名截止">
										{formatDeadline(offering.registrationDeadline)}
									</Field>
									<Field label="名额">
										{offering.capacity === null
											? `不限（已确认 ${offering.confirmedCount ?? 0}）`
											: `${offering.confirmedCount ?? 0} / ${offering.capacity}`}
									</Field>
									<Field label="待审批报名">
										{pendingCount === null ? "—" : pendingCount}
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
												disabled={saveBusy || offering.visibility === v}
												onClick={() => void saveVisibility(v)}
												className={`rounded-full border px-3 py-1 text-[13px] ${
													offering.visibility === v
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
											终态{label}无可执行的生命周期操作（v1 终态不可逆）。
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

/* ---------------- 新建页 ---------------- */

export function OfferingNewPage({ slug, kind }: { slug: string; kind: OfferingKind }) {
	const router = useRouter();
	const { ws, loading: wsLoading } = useWorkspaceBySlugWrapper(slug);

	const [title, setTitle] = useState("");
	const [enrollmentPolicy, setEnrollmentPolicy] = useState<EnrollmentPolicy>("open");
	const [visibility, setVisibility] = useState<Visibility>("public");
	const [capacity, setCapacity] = useState("");
	const [deadline, setDeadline] = useState("");
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);

	const manage = ws ? canManageEvents(ws.myRoleNames) : false;
	const label = OFFERING_LABEL[kind];
	const base = `/w/${slug}/${kind === "event" ? "events" : "courses"}`;

	async function submit() {
		if (!ws) return;
		setBusy(true);
		setError(null);
		try {
			const res = await createOffering(ws.id, kind, {
				title: title.trim(),
				enrollmentPolicy,
				visibility,
				capacity: capacity === "" ? null : Number(capacity),
				registrationDeadline: deadline ? new Date(deadline).toISOString() : null,
			});
			if (res.result) {
				router.push(`${base}/${res.result.id}`);
			} else {
				setError(res.errors[0]?.message ?? "创建失败");
			}
		} catch (e: unknown) {
			setError(e instanceof Error ? e.message : "创建失败");
		} finally {
			setBusy(false);
		}
	}

	if (wsLoading) {
		return (
			<WorkspaceShell slug={slug}>
				<div className="ws-page-main__inner">
					<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
				</div>
			</WorkspaceShell>
		);
	}

	if (!manage) {
		return (
			<WorkspaceShell slug={slug}>
				<div className="ws-page-main__inner">
					<div className="rounded-large border border-line bg-card p-10 text-center text-sm text-ink-3">
						仅 Owner/Admin 可创建{label}。
						<Link href={base} className="ml-2 text-accent">
							返回{label}列表
						</Link>
					</div>
				</div>
			</WorkspaceShell>
		);
	}

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={base}>{label}</Link>
					<span>›</span>
					<strong>新建{label}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>新建{label}</h1>
						<p>创建后为草稿，发布后进入开放报名</p>
					</div>
				</header>

				<div className="max-w-xl rounded-large border border-line bg-card p-6">
					<div className="grid gap-4">
						<label className="block">
							<span className="block text-[13px] text-ink-3">标题（必填）</span>
							<input
								value={title}
								onChange={(e) => setTitle(e.target.value)}
								className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
							/>
						</label>

						<label className="block">
							<span className="block text-[13px] text-ink-3">报名策略</span>
							<select
								value={enrollmentPolicy}
								onChange={(e) =>
									setEnrollmentPolicy(e.target.value as EnrollmentPolicy)
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

						<div>
							<span className="block text-[13px] text-ink-3">可见性</span>
							<div className="mt-2 flex gap-2">
								{VISIBILITIES.map((v) => (
									<button
										key={v}
										type="button"
										onClick={() => setVisibility(v)}
										className={`rounded-full border px-3 py-1 text-[13px] ${
											visibility === v
												? "border-accent bg-soft-2 text-accent"
												: "border-line text-ink-3 hover:border-line-strong"
										}`}
									>
										{VISIBILITY_LABEL[v]}
									</button>
								))}
							</div>
						</div>

						<label className="block">
							<span className="block text-[13px] text-ink-3">
								名额上限（留空 = 不限）
							</span>
							<input
								type="number"
								min={1}
								value={capacity}
								onChange={(e) => setCapacity(e.target.value)}
								className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
							/>
						</label>

						<label className="block">
							<span className="block text-[13px] text-ink-3">
								报名截止（留空 = 不设截止）
							</span>
							<input
								type="datetime-local"
								value={deadline}
								onChange={(e) => setDeadline(e.target.value)}
								className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
							/>
						</label>

						{error ? <p className="text-[13px] text-ink-3">{error}</p> : null}

						<button
							type="button"
							disabled={busy || title.trim() === ""}
							onClick={() => void submit()}
							className="rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
						>
							{busy ? "创建中…" : `创建${label}`}
						</button>
					</div>
				</div>
			</div>
		</WorkspaceShell>
	);
}

/* ---------------- 内部 ---------------- */

import { useWorkspaceBySlug as useWorkspaceBySlugWrapper } from "@/lib/use-workspace-by-slug";
