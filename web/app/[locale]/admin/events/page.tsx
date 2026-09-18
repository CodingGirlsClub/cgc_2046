"use client";

/**
 * /admin/events Event 治理 tab（U3；R1-R6，KTD3/KTD4/KTD6）。
 *
 * 同页模式（KTD6，不建子路由）：列表（搜索 / 状态 / 工作台过滤 + 分页）
 * + 行展开详情（四类排查投影）+ 行内生命周期操作 + 元数据编辑。
 *
 * KTD4（session-settled）取数纪律：
 * - 列表不回读展示投影列；**权威计数只在 `fetchAdminEvent` 现取**，
 *   详情展开与高危确认（关槽位 / 取消）共用这一口。
 * - `confirmedCount` / `paymentPendingCount` 为 `null` = 计数不可用（不是 0）：
 *   渲染不可用态、禁用依赖它的入口，绝不落假值。
 * - 高危确认的笔数单一来源 = 打开确认时现取一次：取数中渲染 loading、
 *   取不到渲染不可用态；写成功后重取刷新（详情重载 + 列表重取）。
 * - 待付 > 200（批量免缴上限）时关槽位入口隐藏，引导走「取消活动」。
 */

import {
	Fragment,
	Suspense,
	useCallback,
	useEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import { useSearchParams } from "next/navigation";
import { useLocale, useTranslations } from "next-intl";
import {
	adminCancelEvent,
	adminCloseEvent,
	adminLaunchEvent,
	adminUpdateEvent,
	fetchAdminEvent,
	fetchAdminEvents,
	fetchReconciliationFindings,
	fetchWorkspaces,
	type AdminEventFilters,
} from "@/lib/admin";
import { copyText } from "@/lib/clipboard";
import { venueDraftToJson } from "@/lib/events";
import { formatDateTime, fromLocalInput, toLocalInput } from "@/lib/format";
import { formatVenue, parseVenue } from "@/lib/public-offerings";
import { localizedUrl } from "@/lib/seo";
import {
	OFFERING_STATUS_CLASS,
	OFFERING_STATUS_VALUES,
	OFFERING_VISIBILITY_VALUES,
	RECONCILIATION_ENTITY_LABEL,
	RECONCILIATION_RULE_LABEL,
	type AdminEvent,
	type AdminEventDetail,
	type AdminEventPayload,
	type AdminEventUpdateInput,
	type AdminReconciliationFinding,
	type AdminWorkspace,
} from "@/lib/graphql/admin";
import type { VenueInfo } from "@/lib/graphql/events";
import type { MutationError } from "@/lib/graphql/shared";

const PAGE_SIZE = 20;

/**
 * 批量免缴上限（`waive_pending_on_fee_slot_disable.ex` 超限整笔回滚）：
 * 待付笔数超此值时治理面不提供关槽位入口，引导走 cancel。
 */
const WAIVE_PENDING_LIMIT = 200;

const VENUE_KEYS = ["country", "province", "city", "district"] as const;

const EMPTY_VENUE: VenueInfo = { country: "", province: "", city: "", district: "" };

/** 展开详情的取数状态：`unavailable` 同时覆盖「加载失败」与「id 不存在」，界面区分文案 */
type DetailState =
	| { status: "loading" }
	| { status: "ready"; event: AdminEventDetail }
	| { status: "unavailable" };

/** 权威计数现取结果（`null` 计数 = 不可用，不是 0） */
type Counts =
	| { status: "ready"; confirmed: number | null; pending: number | null }
	| { status: "unavailable" }
	| { status: "notfound" };

type FeeSlot = "pricing" | "deposit";

/** 元数据编辑草稿（datetime-local 原值 + venue 四键草稿；未提交前不动详情真值） */
interface EditDraft {
	title: string;
	startsAt: string;
	endsAt: string;
	registrationDeadline: string;
	capacity: string;
	visibility: string;
	pricingEnabled: boolean;
	depositEnabled: boolean;
	venue: VenueInfo;
}

function draftFromEvent(event: AdminEventDetail): EditDraft {
	return {
		title: event.title,
		startsAt: toLocalInput(event.startsAt),
		endsAt: toLocalInput(event.endsAt),
		registrationDeadline: toLocalInput(event.registrationDeadline),
		capacity: event.capacity == null ? "" : String(event.capacity),
		visibility: event.visibility,
		pricingEnabled: event.pricingEnabled,
		depositEnabled: event.depositEnabled,
		venue: parseVenue(event.venue) ?? { ...EMPTY_VENUE },
	};
}

type DraftDiff =
	| {
			ok: true;
			/** 只含**本次真变更**的键（同值重发会误写缴费槽位决定，且分钟精度会截断秒） */
			input: AdminEventUpdateInput;
			/** 本次提交会关停的缴费槽位（true→false，可能两个同批）——高危确认的触发条件 */
			closedSlots: FeeSlot[];
	  }
	| { ok: false; issue: "title" | "capacity" | "venue" };

/**
 * 草稿 vs 服务端快照 → 治理 update 输入。
 *
 * 时间字段用 `toLocalInput(服务端值) === 草稿` 判脏：datetime-local 只到分钟，
 * 未改动不下发，避免把库里的秒截断（workbench 表单同款脏检查纪律）。
 */
function diffDraft(draft: EditDraft, event: AdminEventDetail): DraftDiff {
	const title = draft.title.trim();
	if (title === "") return { ok: false, issue: "title" };

	const capacityRaw = draft.capacity.trim();
	let capacity = event.capacity ?? null;
	if (capacityRaw !== "") {
		const parsed = Number(capacityRaw);
		if (!Number.isInteger(parsed) || parsed <= 0) return { ok: false, issue: "capacity" };
		capacity = parsed;
	}

	const venue: VenueInfo = {
		country: draft.venue.country.trim(),
		province: draft.venue.province.trim(),
		city: draft.venue.city.trim(),
		district: draft.venue.district.trim(),
	};
	const filled = VENUE_KEYS.filter((key) => venue[key] !== "").length;
	if (filled > 0 && filled < VENUE_KEYS.length) return { ok: false, issue: "venue" };

	const input: AdminEventUpdateInput = {};
	if (title !== event.title) input.title = title;
	if (capacity !== (event.capacity ?? null)) input.capacity = capacity;
	if (draft.startsAt !== toLocalInput(event.startsAt)) input.startsAt = fromLocalInput(draft.startsAt);
	if (draft.endsAt !== toLocalInput(event.endsAt)) input.endsAt = fromLocalInput(draft.endsAt);
	if (draft.registrationDeadline !== toLocalInput(event.registrationDeadline)) {
		input.registrationDeadline = fromLocalInput(draft.registrationDeadline);
	}
	if (draft.visibility !== event.visibility) input.visibility = draft.visibility;
	if (event.pricingEnabled !== draft.pricingEnabled) input.pricingEnabled = draft.pricingEnabled;
	if (event.depositEnabled !== draft.depositEnabled) input.depositEnabled = draft.depositEnabled;

	const serverVenue = parseVenue(event.venue) ?? { ...EMPTY_VENUE };
	if (VENUE_KEYS.some((key) => venue[key] !== serverVenue[key].trim())) {
		input.venue = venueDraftToJson(draft.venue);
	}

	const closedSlots: FeeSlot[] = [];
	if (input.pricingEnabled === false) closedSlots.push("pricing");
	if (input.depositEnabled === false) closedSlots.push("deposit");

	return { ok: true, input, closedSlots };
}

/**
 * 缴费槽位开关（KTD4 的「关槽位入口」）：
 * - 槽位当前为开、待付 > 200（批量免缴上限）→ **隐藏入口**，引导走 cancel；
 * - 槽位当前为开、计数不可用（null）→ 入口禁用，不给基于假 0 的关停机会；
 * - 槽位当前为关 → 任意切换（开启无批量免缴后果，不受计数约束）。
 */
function FeeSlotField({
	label,
	amountHint,
	enabled,
	pendingCount,
	checked,
	onChange,
}: {
	label: string;
	amountHint?: string;
	enabled: boolean;
	pendingCount: number | null;
	checked: boolean;
	onChange: (next: boolean) => void;
}) {
	const t = useTranslations("admin");
	const overLimit = enabled && pendingCount !== null && pendingCount > WAIVE_PENDING_LIMIT;
	return (
		<div className="admin-field">
			<span className="admin-field__label">{label}</span>
			{overLimit ? (
				<p className="admin-muted">{t("eventSlotEntryHidden", { count: pendingCount ?? 0 })}</p>
			) : (
				<label>
					<input
						type="checkbox"
						aria-label={label}
						checked={checked}
						disabled={enabled && pendingCount === null}
						onChange={(e) => onChange(e.currentTarget.checked)}
					/>{" "}
					{checked ? t("initiativeMountOn") : t("initiativeMountOff")}
				</label>
			)}
			{enabled && pendingCount === null ? (
				<p className="admin-muted">{t("eventSlotEntryDisabled")}</p>
			) : null}
			{amountHint ? <span className="admin-field__hint">{amountHint}</span> : null}
		</div>
	);
}

export default function AdminEventsPage() {
	return (
		// Next.js 16：useSearchParams（对账跳转落点 ?entity_id=）需包 Suspense 边界（issue #73）
		<Suspense fallback={<p className="admin-muted">…</p>}>
			<AdminEventsContent />
		</Suspense>
	);
}

function AdminEventsContent() {
	const t = useTranslations("admin");
	const labelsT = useTranslations();
	const errorT = useTranslations("errors");
	const offeringsT = useTranslations("offerings");
	const locale = useLocale();
	const searchParams = useSearchParams();
	/** 对账页跳转落点（R3/AE4）：/admin/events?entity_id=<uuid> 定位并自动展开该行 */
	const targetEntityId = searchParams?.get("entity_id") ?? null;

	// ---- 列表 ----
	const [rows, setRows] = useState<AdminEvent[] | null>(null);
	const [listError, setListError] = useState(false);
	const [loading, setLoading] = useState(false);
	const [search, setSearch] = useState("");
	const [status, setStatus] = useState("");
	const [workspaceId, setWorkspaceId] = useState("");
	const [applied, setApplied] = useState<AdminEventFilters>({});
	const [offset, setOffset] = useState(0);
	const [workspaces, setWorkspaces] = useState<AdminWorkspace[]>([]);

	// ---- 详情（KTD4 计数唯一现取口）----
	const [expand, setExpand] = useState<{ id: string; state: DetailState } | null>(() =>
		targetEntityId ? { id: targetEntityId, state: { status: "loading" } } : null,
	);
	const [findings, setFindings] = useState<{
		id: string;
		list: AdminReconciliationFinding[] | null;
		failed: boolean;
	} | null>(null);

	// ---- 编辑与高危确认 ----
	const [draft, setDraft] = useState<EditDraft | null>(null);
	const [slotConfirm, setSlotConfirm] = useState<{
		eventId: string;
		slots: FeeSlot[];
		input: AdminEventUpdateInput;
		counts: { status: "loading" } | Counts;
	} | null>(null);
	const [busy, setBusy] = useState<string | null>(null);
	const [actionError, setActionError] = useState<string | null>(null);
	const [hint, setHint] = useState<string | null>(null);
	const [copiedId, setCopiedId] = useState<string | null>(null);
	/** 列表读序号：过滤/分页连点时只让最后一次发出的读落地 */
	const listSeqRef = useRef(0);
	/** 详情读序号：详情与 findings 共用，切换行/重取时丢弃迟到回包 */
	const detailSeqRef = useRef(0);
	/** 弹层焦点约束（自绘 modal 的焦点不进背后面板） */
	const cancelButtonRef = useRef<HTMLButtonElement | null>(null);
	const confirmButtonRef = useRef<HTMLButtonElement | null>(null);

	const loadList = useCallback((filters: AdminEventFilters, after: number) => {
		const seq = ++listSeqRef.current;
		// .then/.catch 链（users 页模式）：effect 内调用不触发 set-state-in-effect
		return fetchAdminEvents(filters, { first: PAGE_SIZE, after: String(after) })
			.then((list) => {
				if (listSeqRef.current !== seq) return;
				setRows(list);
				setListError(false);
			})
			.catch(() => {
				if (listSeqRef.current !== seq) return;
				setListError(true);
				setRows([]);
			})
			.finally(() => {
				if (listSeqRef.current === seq) setLoading(false);
			});
	}, []);

	const loadDetail = useCallback((id: string) => {
		const seq = ++detailSeqRef.current;
		void fetchAdminEvent(id)
			.then((event) => {
				if (detailSeqRef.current !== seq) return;
				setExpand((current) =>
					current?.id === id
						? { id, state: event ? { status: "ready", event } : { status: "unavailable" } }
						: current,
				);
			})
			.catch(() => {
				if (detailSeqRef.current !== seq) return;
				setExpand((current) =>
					current?.id === id ? { id, state: { status: "unavailable" } } : current,
				);
			});
		// KTD5：findings 强制成对过滤（entityType + entityId）
		void fetchReconciliationFindings({ entityType: "event", entityId: id })
			.then((list) => {
				if (detailSeqRef.current !== seq) return;
				setFindings({ id, list, failed: false });
			})
			.catch(() => {
				if (detailSeqRef.current !== seq) return;
				setFindings({ id, list: null, failed: true });
			});
	}, []);

	useEffect(() => {
		void loadList({}, 0);
	}, [loadList]);

	useEffect(() => {
		// 工作台选择器与行内名称映射同源：一次拉取（R2）
		void fetchWorkspaces(undefined, { first: 200 })
			.then((list) => setWorkspaces(list))
			.catch(() => setWorkspaces([]));
	}, []);

	const loadingId = expand && expand.state.status === "loading" ? expand.id : null;
	useEffect(() => {
		if (!loadingId) return;
		loadDetail(loadingId);
	}, [loadingId, loadDetail]);

	// 弹层焦点约束：Escape 取消；Tab 一律拦截重分配，不放焦点进背后面板（initiatives 先例）
	useEffect(() => {
		if (!slotConfirm) return;
		// 确认按钮在取数完成前是禁用的：此时把焦点落在可点的「取消」上，
		// 避免焦点留在背后面板（对 disabled 元素 focus() 是空操作）
		const confirmButton = confirmButtonRef.current;
		(confirmButton && !confirmButton.disabled ? confirmButton : cancelButtonRef.current)?.focus();
		function onKeyDown(event: KeyboardEvent) {
			if (event.key === "Escape") {
				setSlotConfirm(null);
				return;
			}
			if (event.key !== "Tab") return;
			const first = cancelButtonRef.current;
			const last = confirmButtonRef.current;
			if (!first || !last) return;
			event.preventDefault();
			const confirmEnabled = !last.disabled;
			const active = document.activeElement;
			if (active === last) {
				first.focus();
				return;
			}
			if (active === first) {
				if (confirmEnabled) last.focus();
				return;
			}
			(confirmEnabled ? last : first).focus();
		}
		document.addEventListener("keydown", onKeyDown);
		return () => document.removeEventListener("keydown", onKeyDown);
	}, [slotConfirm]);

	const workspaceName = useCallback(
		(id: string) => workspaces.find((item) => item.id === id)?.name ?? null,
		[workspaces],
	);

	const expandedEvent = expand?.state.status === "ready" ? expand.state.event : null;
	/** 对账定位行：不在当前列表里也要可见（否则跳转落空） */
	const visibleRows = useMemo(() => {
		if (!expandedEvent) return rows;
		const list = rows ?? [];
		if (list.some((row) => row.id === expandedEvent.id)) return rows;
		return [expandedEvent, ...list];
	}, [rows, expandedEvent]);
	const pinnedOutsideList =
		expandedEvent !== null && rows !== null && !rows.some((row) => row.id === expandedEvent.id);
	const currentFindings =
		findings && expand && findings.id === expand.id ? findings : null;
	/** KTD4：计数一律按「null/undefined = 不可用」归一，绝不落假 0 */
	const confirmedCount = expandedEvent?.confirmedCount ?? null;
	const pendingCount = expandedEvent?.paymentPendingCount ?? null;

	/** 写失败文案：稳定 code（如 event_slug_locked）走 errors 命名空间本地化，其余回落后端 message */
	function mutationErrorText(errors: MutationError[]): string {
		const failure = errors[0];
		if (!failure) return t("eventSaveFailed");
		if (failure.code && errorT.has(failure.code)) return errorT(failure.code);
		return failure.message || t("eventSaveFailed");
	}

	/**
	 * 权威计数现取（KTD4）：详情与确认弹窗共用。
	 * id 不存在单独成态——不把它混进「计数不可用」，避免用户对着已不存在的实体操作。
	 */
	async function fetchCounts(id: string): Promise<Counts> {
		try {
			const event = await fetchAdminEvent(id);
			if (!event) return { status: "notfound" };
			return {
				status: "ready",
				confirmed: event.confirmedCount ?? null,
				pending: event.paymentPendingCount ?? null,
			};
		} catch {
			return { status: "unavailable" };
		}
	}

	/** 写成功后：列表按当前过滤重取；展开中的行重取详情（计数刷新，KTD4） */
	function refreshAfterWrite(id: string) {
		void loadList(applied, offset);
		if (expand?.id !== id) return;
		setDraft(null);
		setExpand({ id, state: { status: "loading" } });
	}

	async function runMutation(
		id: string,
		run: () => Promise<AdminEventPayload>,
	): Promise<void> {
		setBusy(id);
		setActionError(null);
		setHint(null);
		try {
			const payload = await run();
			if (!payload.result) {
				setActionError(mutationErrorText(payload.errors));
				return;
			}
			setHint(t("eventSaved"));
			refreshAfterWrite(id);
		} catch {
			// 传输层 / 顶层 GraphQL 错误（unauthorized/forbidden/5xx）：必须可见，不静默
			setActionError(t("eventSaveFailedNetwork"));
		} finally {
			setBusy(null);
		}
	}

	function toggleDetail(row: AdminEvent) {
		setActionError(null);
		setHint(null);
		setDraft(null);
		if (expand?.id === row.id) {
			setExpand(null);
			return;
		}
		setExpand({ id: row.id, state: { status: "loading" } });
	}

	function applyFilters() {
		const next: AdminEventFilters = {
			search: search.trim() || undefined,
			status: status || undefined,
			workspaceId: workspaceId || undefined,
		};
		setApplied(next);
		setOffset(0);
		setLoading(true);
		void loadList(next, 0);
	}

	function goNext() {
		const next = offset + (rows?.length ?? 0);
		setOffset(next);
		setLoading(true);
		void loadList(applied, next);
	}

	function goPrev() {
		const prev = Math.max(offset - PAGE_SIZE, 0);
		setOffset(prev);
		setLoading(true);
		void loadList(applied, prev);
	}

	/**
	 * 取消活动（不可逆）：确认前现取权威计数并披露受影响笔数；
	 * 取不到数字时如实披露「不可用」，既不落假 0 也不省略二次确认。
	 */
	async function cancelEvent(row: AdminEvent) {
		setBusy(row.id);
		setActionError(null);
		setHint(null);
		const counts = await fetchCounts(row.id);
		if (counts.status === "notfound") {
			setBusy(null);
			setActionError(t("eventNotFound"));
			return;
		}
		const message =
			counts.status === "ready" && counts.confirmed !== null && counts.pending !== null
				? t("eventCancelConfirm", {
						title: row.title,
						confirmed: counts.confirmed,
						pending: counts.pending,
					})
				: t("eventCancelConfirmUnavailable", { title: row.title });
		setBusy(null);
		if (!window.confirm(message)) return;
		await runMutation(row.id, () => adminCancelEvent(row.id));
	}

	function saveMetadata() {
		if (expand?.state.status !== "ready" || !draft) return;
		const event = expand.state.event;
		const diff = diffDraft(draft, event);
		if (!diff.ok) {
			setHint(null);
			setActionError(
				diff.issue === "title"
					? t("eventTitleRequired")
					: diff.issue === "capacity"
						? t("eventCapacityInvalid")
						: offeringsT("venueIncomplete"),
			);
			return;
		}
		if (Object.keys(diff.input).length === 0) {
			setActionError(null);
			setHint(t("eventNoChanges"));
			return;
		}
		setActionError(null);
		setHint(null);
		if (diff.closedSlots.length > 0) {
			// 关槽位有级联财务后果（批量免缴）→ 先过确认弹层，不直写
			requestSlotSave(event.id, diff.closedSlots, diff.input);
			return;
		}
		void runMutation(event.id, () => adminUpdateEvent(event.id, diff.input));
	}

	/** 打开关槽位确认：数字单一来源 = 此刻现取一次（弹层内渲染 loading / 不可用态） */
	function requestSlotSave(eventId: string, slots: FeeSlot[], input: AdminEventUpdateInput) {
		setSlotConfirm({ eventId, slots, input, counts: { status: "loading" } });
		void fetchCounts(eventId).then((counts) => {
			setSlotConfirm((current) =>
				current && current.eventId === eventId ? { ...current, counts } : current,
			);
		});
	}

	function confirmSlotSave() {
		if (!slotConfirm) return;
		const { eventId, input } = slotConfirm;
		setSlotConfirm(null);
		void runMutation(eventId, () => adminUpdateEvent(eventId, input));
	}

	async function copyLink(row: AdminEvent) {
		if (!row.slug) return;
		const ok = await copyText(localizedUrl(`/events/${row.slug}`, locale));
		if (!ok) return;
		setCopiedId(row.id);
		setTimeout(() => setCopiedId((current) => (current === row.id ? null : current)), 2000);
	}

	const slotCounts = slotConfirm?.counts ?? null;
	const slotPending = slotCounts && slotCounts.status === "ready" ? slotCounts.pending : null;
	const slotOverLimit = slotPending !== null && slotPending > WAIVE_PENDING_LIMIT;
	const slotConfirmEnabled = slotPending !== null && !slotOverLimit;

	return (
		<section>
			<div className="admin-page__head">
				<div>
					<h1>{t("eventsTitle")}</h1>
					<p className="admin-page__desc">{t("eventsDesc")}</p>
				</div>
			</div>

			<div className="admin-toolbar">
				<input
					value={search}
					onChange={(e) => setSearch(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && applyFilters()}
					placeholder={t("eventSearchPlaceholder")}
					aria-label={t("eventSearchAria")}
					className="l-input"
				/>
				<select
					value={status}
					onChange={(e) => setStatus(e.target.value)}
					aria-label={t("eventStatusAria")}
					className="l-input"
				>
					<option value="">{t("allStatuses")}</option>
					{OFFERING_STATUS_VALUES.map((value) => (
						<option key={value} value={value}>
							{labelsT(`labels.eventStatus.${value}`)}
						</option>
					))}
				</select>
				<select
					value={workspaceId}
					onChange={(e) => setWorkspaceId(e.target.value)}
					aria-label={t("eventWorkspaceAria")}
					className="l-input"
				>
					<option value="">{t("eventWorkspaceAll")}</option>
					{workspaces.map((workspace) => (
						<option key={workspace.id} value={workspace.id}>
							{workspace.name}
						</option>
					))}
				</select>
				<button type="button" onClick={applyFilters} className="l-btn-outline">
					{t("filter")}
				</button>
			</div>

			{actionError ? (
				<p className="admin-alert admin-alert--error" role="alert">
					{actionError}
				</p>
			) : null}
			{hint ? <p className="admin-muted">{hint}</p> : null}

			{listError ? (
				<p className="admin-alert admin-alert--error" role="alert">
					{t("loadFailed")}
				</p>
			) : null}

			{visibleRows === null ? (
				<p className="admin-muted">{t("loading")}</p>
			) : visibleRows.length === 0 ? (
				// 列表读失败且无对账定位行：只留上面的错误提示，不落「暂无活动」假空态
				listError ? null : <p className="admin-empty">{t("eventsEmpty")}</p>
			) : (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("eventTitle")}</th>
								<th>{t("initiativeSlug")}</th>
								<th>{t("initiativeStatus")}</th>
								<th className="admin-table__num">{t("eventCapacity")}</th>
								<th>{t("eventWorkspace")}</th>
								<th>{t("eventStartsAt")}</th>
								<th className="admin-table__actions">{t("initiativeAction")}</th>
							</tr>
						</thead>
						<tbody>
							{visibleRows.map((row) => {
								const expanded = expand?.id === row.id;
								const detailState = expanded ? expand?.state ?? null : null;
								const workspace = workspaceName(row.workspaceId);
								const publicUrl = row.slug
									? localizedUrl(`/events/${row.slug}`, locale)
									: null;
								return (
									<Fragment key={row.id}>
										<tr>
											<td>
												<span className="admin-table__primary">{row.title}</span>
												{pinnedOutsideList && expandedEvent?.id === row.id ? (
													<span className="admin-table__sub">
														{t("eventPinnedHint")}
													</span>
												) : null}
											</td>
											<td>{row.slug ?? "—"}</td>
											<td>
												<span
													className={
														OFFERING_STATUS_CLASS[row.status] ?? "l-badge l-badge-muted"
													}
												>
													{labelsT(`labels.eventStatus.${row.status}`)}
												</span>
											</td>
											<td className="admin-table__num">
												{row.capacity ?? t("eventCapacityUnlimited")}
											</td>
											<td>
												{workspace ?? <span className="l-mono">{row.workspaceId}</span>}
											</td>
											<td>
												<div>{`${t("eventStartsAt")}：${formatDateTime(row.startsAt)}`}</div>
												<div className="admin-muted">{`${t("eventDeadline")}：${formatDateTime(
													row.registrationDeadline,
												)}`}</div>
											</td>
											<td className="admin-table__actions">
												<button
													type="button"
													className="l-btn-outline"
													aria-expanded={expanded}
													onClick={() => toggleDetail(row)}
												>
													{expanded ? t("eventDetailHide") : t("eventDetail")}
												</button>
												{/* 按钮可见性矩阵（KTD6）：draft 只有发布；open 有结束 + 取消；终态无出边 */}
												{row.status === "draft" ? (
													<button
														type="button"
														className="l-btn-outline"
														disabled={busy === row.id}
														onClick={() =>
															void runMutation(row.id, () => adminLaunchEvent(row.id))
														}
													>
														{t("eventLaunch")}
													</button>
												) : null}
												{row.status === "open" ? (
													<>
														<button
															type="button"
															className="l-btn-outline"
															disabled={busy === row.id}
															onClick={() =>
																void runMutation(row.id, () => adminCloseEvent(row.id))
															}
														>
															{t("eventClose")}
														</button>
														<button
															type="button"
															className="l-btn-outline l-btn-outline--danger"
															disabled={busy === row.id}
															onClick={() => void cancelEvent(row)}
														>
															{t("eventCancel")}
														</button>
													</>
												) : null}
											</td>
										</tr>
										{expanded ? (
											<tr>
												<td colSpan={7}>
													{detailState?.status === "loading" ? (
														<p className="admin-muted">{t("loading")}</p>
													) : detailState?.status === "unavailable" ? (
														<p className="admin-alert admin-alert--error" role="alert">
															{t("eventDetailUnavailable")}
														</p>
													) : expandedEvent ? (
														<div className="admin-card admin-card__body">
															<h3 className="admin-section-title">
																{t("eventBasic")}
															</h3>
															<div className="admin-form">
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("eventPublicLink")}
																	</span>
																	{publicUrl && expandedEvent.slug ? (
																		<span>
																			<a
																				href={publicUrl}
																				target="_blank"
																				rel="noreferrer"
																				className="admin-link"
																			>
																				{publicUrl}
																			</a>
																			<button
																				type="button"
																				className="l-btn-outline"
																				onClick={() => void copyLink(expandedEvent)}
																			>
																				{copiedId === expandedEvent.id
																					? t("initiativeLinkCopied")
																					: t("initiativeCopyLink")}
																			</button>
																		</span>
																	) : (
																		<span className="admin-muted">
																			{t("eventSlugMissing")}
																		</span>
																	)}
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("initiativeStatus")}
																	</span>
																	<span
																		className={
																			OFFERING_STATUS_CLASS[expandedEvent.status] ??
																			"l-badge l-badge-muted"
																		}
																	>
																		{labelsT(
																			`labels.eventStatus.${expandedEvent.status}`,
																		)}
																	</span>
																	<span className="admin-muted">
																		{labelsT(
																			`labels.visibility.${expandedEvent.visibility}`,
																		)}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("eventWorkspace")}
																	</span>
																	<span>
																		{workspaceName(expandedEvent.workspaceId) ?? (
																			<span className="l-mono">
																				{expandedEvent.workspaceId}
																			</span>
																		)}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("eventStartsAt")}
																	</span>
																	<span>
																		{`${formatDateTime(expandedEvent.startsAt)} → ${formatDateTime(
																			expandedEvent.endsAt,
																		)}`}
																	</span>
																	<span className="admin-field__hint">
																		{`${t("eventDeadline")}：${formatDateTime(
																			expandedEvent.registrationDeadline,
																		)}`}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("eventVenue")}
																	</span>
																	<span>
																		{formatVenue(parseVenue(expandedEvent.venue)) ??
																			t("eventVenueTbd")}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("eventCapacity")}
																	</span>
																	<span>
																		{expandedEvent.capacity ??
																			t("eventCapacityUnlimited")}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("eventConfirmedCount")}
																	</span>
																	{/* KTD4：null = 计数不可用，不落假值 */}
																	<span
																		className={
																			confirmedCount === null ? "admin-muted" : undefined
																		}
																	>
																		{confirmedCount === null
																			? t("eventCountsUnavailable")
																			: confirmedCount}
																	</span>
																	<span className="admin-field__hint">
																		{`${t("eventPendingCount")}：${
																			pendingCount === null
																				? t("eventCountsUnavailable")
																				: pendingCount
																		}`}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("eventModerators")}
																	</span>
																	{expandedEvent.moderators === null ||
																	expandedEvent.moderators === undefined ? (
																		<span className="admin-muted">
																			{t("eventModeratorsUnavailable")}
																		</span>
																	) : expandedEvent.moderators.length === 0 ? (
																		<span className="admin-muted">
																			{t("eventModeratorsEmpty")}
																		</span>
																	) : (
																		<span className="l-mono">
																			{expandedEvent.moderators
																				.map((moderator) => moderator.userId)
																				.join("、")}
																		</span>
																	)}
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("eventDetachedProvenance")}
																	</span>
																	<span className="l-mono">
																		{expandedEvent.detachedRuleProvenance ??
																			t("eventDetachedNone")}
																	</span>
																</div>
															</div>

															<h3 className="admin-section-title">
																{t("eventFindings")}
															</h3>
															{currentFindings?.failed ? (
																<p className="admin-alert admin-alert--error">
																	{t("eventFindingsUnavailable")}
																</p>
															) : currentFindings?.list ? (
																currentFindings.list.length === 0 ? (
																	<p className="admin-muted">
																		{t("eventFindingsEmpty")}
																	</p>
																) : (
																	<div className="admin-table-wrap">
																		<table className="admin-table">
																			<thead>
																				<tr>
																					<th>{t("thRule")}</th>
																					<th>{t("thEntity")}</th>
																					<th>{t("thId")}</th>
																					<th>{t("thFirstSeen")}</th>
																					<th>{t("thLastSeen")}</th>
																				</tr>
																			</thead>
																			<tbody>
																				{currentFindings.list.map((finding) => (
																					<tr key={finding.id}>
																						<td>
																							{labelsT(
																								RECONCILIATION_RULE_LABEL[finding.rule] ??
																									finding.rule,
																							)}
																						</td>
																						<td>
																							{labelsT(
																								RECONCILIATION_ENTITY_LABEL[
																									finding.entityType
																								] ?? finding.entityType,
																							)}
																						</td>
																						<td className="l-mono">
																							{finding.entityId}
																						</td>
																						<td>
																							{formatDateTime(finding.firstSeenAt)}
																						</td>
																						<td>
																							{formatDateTime(finding.lastSeenAt)}
																						</td>
																					</tr>
																				))}
																			</tbody>
																		</table>
																	</div>
																)
															) : (
																<p className="admin-muted">{t("loading")}</p>
															)}

															{draft ? (
																<>
																	<h3 className="admin-section-title">
																		{t("eventEditMetadata")}
																	</h3>
																	<div className="admin-form">
																		<div className="admin-field">
																			<label
																				htmlFor="event-detail-slug"
																				className="admin-field__label"
																			>
																				{t("initiativeSlug")}
																			</label>
																			{/* slug 治理面只读展示：已发布实体的 slug 改动由后端
																			    `event_slug_locked` 拒绝（R7/AE5） */}
																			<input
																				id="event-detail-slug"
																				className="l-input"
																				value={expandedEvent.slug ?? ""}
																				readOnly
																			/>
																			{expandedEvent.status !== "draft" ? (
																				<p className="admin-muted">
																					{t("initiativeSlugLocked")}
																				</p>
																			) : null}
																		</div>
																		<div className="admin-field">
																			<label
																				htmlFor="event-detail-title"
																				className="admin-field__label"
																			>
																				{t("eventTitle")}
																			</label>
																			<input
																				id="event-detail-title"
																				className="l-input"
																				value={draft.title}
																				onChange={(e) =>
																					setDraft({ ...draft, title: e.target.value })
																				}
																			/>
																		</div>
																		<div className="admin-field">
																			<label
																				htmlFor="event-detail-starts"
																				className="admin-field__label"
																			>
																				{t("eventStartsAt")}
																			</label>
																			<input
																				id="event-detail-starts"
																				type="datetime-local"
																				className="l-input"
																				value={draft.startsAt}
																				onChange={(e) =>
																					setDraft({ ...draft, startsAt: e.target.value })
																				}
																			/>
																		</div>
																		<div className="admin-field">
																			<label
																				htmlFor="event-detail-ends"
																				className="admin-field__label"
																			>
																				{t("eventEndsAt")}
																			</label>
																			<input
																				id="event-detail-ends"
																				type="datetime-local"
																				className="l-input"
																				value={draft.endsAt}
																				onChange={(e) =>
																					setDraft({ ...draft, endsAt: e.target.value })
																				}
																			/>
																		</div>
																		<div className="admin-field">
																			<label
																				htmlFor="event-detail-deadline"
																				className="admin-field__label"
																			>
																				{t("eventDeadline")}
																			</label>
																			<input
																				id="event-detail-deadline"
																				type="datetime-local"
																				className="l-input"
																				value={draft.registrationDeadline}
																				onChange={(e) =>
																					setDraft({
																						...draft,
																						registrationDeadline: e.target.value,
																					})
																				}
																			/>
																		</div>
																		<div className="admin-field">
																			<label
																				htmlFor="event-detail-capacity"
																				className="admin-field__label"
																			>
																				{t("eventCapacity")}
																			</label>
																			<input
																				id="event-detail-capacity"
																				className="l-input"
																				value={draft.capacity}
																				placeholder={t("eventCapacityUnlimited")}
																				onChange={(e) =>
																					setDraft({
																						...draft,
																						capacity: e.target.value,
																					})
																				}
																			/>
																		</div>
																		<div className="admin-field">
																			<label
																				htmlFor="event-detail-visibility"
																				className="admin-field__label"
																			>
																				{t("eventVisibility")}
																			</label>
																			<select
																				id="event-detail-visibility"
																				className="l-input"
																				value={draft.visibility}
																				onChange={(e) =>
																					setDraft({
																						...draft,
																						visibility: e.target.value,
																					})
																				}
																			>
																				{OFFERING_VISIBILITY_VALUES.map((value) => (
																					<option key={value} value={value}>
																						{labelsT(`labels.visibility.${value}`)}
																					</option>
																				))}
																			</select>
																		</div>
																		{/* 关槽位入口（KTD4）：待付 > 200 隐藏，计数不可用则禁用 */}
																		<FeeSlotField
																			label={t("eventPricingSlot")}
																			enabled={expandedEvent.pricingEnabled}
																			pendingCount={pendingCount}
																			checked={draft.pricingEnabled}
																			onChange={(next) =>
																				setDraft({ ...draft, pricingEnabled: next })
																			}
																		/>
																		<FeeSlotField
																			label={t("eventDepositSlot")}
																			amountHint={`${t("eventDepositAmount")}：${
																				expandedEvent.depositAmountCents ?? "—"
																			}`}
																			enabled={expandedEvent.depositEnabled}
																			pendingCount={pendingCount}
																			checked={draft.depositEnabled}
																			onChange={(next) =>
																				setDraft({ ...draft, depositEnabled: next })
																			}
																		/>
																		<fieldset className="admin-field">
																			<legend className="admin-field__label">
																				{offeringsT("venueSection")}
																			</legend>
																			{VENUE_KEYS.map((key) => (
																				<label key={key}>
																					<span className="admin-field__hint">
																						{offeringsT(
																							`venue${key[0].toUpperCase()}${key.slice(1)}`,
																						)}
																					</span>
																					<input
																						className="l-input"
																						aria-label={offeringsT(
																							`venue${key[0].toUpperCase()}${key.slice(1)}`,
																						)}
																						value={draft.venue[key]}
																						onChange={(e) =>
																							setDraft({
																								...draft,
																								venue: {
																									...draft.venue,
																									[key]: e.target.value,
																								},
																							})
																						}
																					/>
																				</label>
																			))}
																		</fieldset>
																		<div>
																			<button
																				type="button"
																				className="l-btn-primary"
																				disabled={busy === expandedEvent.id}
																				onClick={() => saveMetadata()}
																			>
																				{t("initiativeSave")}
																			</button>
																			<button
																				type="button"
																				className="l-btn-outline"
																				onClick={() => {
																					setDraft(null);
																					setHint(null);
																				}}
																			>
																				{t("initiativeCancelEdit")}
																			</button>
																		</div>
																	</div>
																</>
															) : (
																<button
																	type="button"
																	className="l-btn-outline"
																	onClick={() => {
																		setActionError(null);
																		setHint(null);
																		setDraft(draftFromEvent(expandedEvent));
																	}}
																>
																	{t("eventEditMetadata")}
																</button>
															)}
														</div>
													) : null}
												</td>
											</tr>
										) : null}
									</Fragment>
								);
							})}
						</tbody>
					</table>
				</div>
			)}

			<div className="admin-pager">
				<button
					type="button"
					onClick={goPrev}
					disabled={offset === 0 || loading}
					className="l-btn-outline"
				>
					{t("prevPage")}
				</button>
				<button
					type="button"
					onClick={goNext}
					disabled={loading || (rows?.length ?? 0) < PAGE_SIZE}
					className="l-btn-outline"
				>
					{t("nextPage")}
				</button>
			</div>

			{slotConfirm ? (
				<div
					role="dialog"
					aria-modal="true"
					aria-label={t("eventSlotImpactTitle")}
					className="admin-modal-overlay"
					onClick={() => setSlotConfirm(null)}
				>
					<div className="admin-modal" onClick={(e) => e.stopPropagation()}>
						<h2>{t("eventSlotImpactTitle")}</h2>
						{slotConfirm.slots.map((slot) => (
							<p key={slot}>
								{t("eventSlotImpactSlot", {
									slot: slot === "pricing" ? t("eventPricingSlot") : t("eventDepositSlot"),
								})}
							</p>
						))}
						{slotCounts === null || slotCounts.status === "loading" ? (
							<p className="admin-muted">{t("eventSlotCountsLoading")}</p>
						) : slotPending === null ? (
							// KTD4：取不到数字 → 不可用态，不落假值，确认保持禁用
							<p className="admin-alert admin-alert--warn">
								{t("eventSlotCountsUnavailable")}
							</p>
						) : slotOverLimit ? (
							<p className="admin-alert admin-alert--warn">
								{t("eventSlotImpactLimit", { count: slotPending })}
							</p>
						) : (
							<>
								<p>{t("eventSlotImpactBody", { count: slotPending })}</p>
								<p className="admin-muted">{t("eventSlotImpactNote")}</p>
							</>
						)}
						<div className="admin-modal__actions">
							<button
								ref={cancelButtonRef}
								type="button"
								className="l-btn-outline"
								onClick={() => setSlotConfirm(null)}
							>
								{t("initiativeCancelEdit")}
							</button>
							<button
								ref={confirmButtonRef}
								type="button"
								className="l-btn-primary"
								disabled={!slotConfirmEnabled}
								onClick={() => confirmSlotSave()}
							>
								{t("eventSlotConfirm")}
							</button>
						</div>
					</div>
				</div>
			) : null}
		</section>
	);
}
