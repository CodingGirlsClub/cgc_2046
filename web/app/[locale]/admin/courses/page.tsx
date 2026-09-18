"use client";

/**
 * /admin/courses Course 治理 tab（U4；R1-R6，KTD3/KTD4/KTD6）。
 *
 * 同页模式（KTD6，不建子路由）：列表（搜索 / 状态 / 工作台过滤 + 分页）
 * + 行展开详情（四类排查投影）+ 行内生命周期操作 + 元数据编辑。
 *
 * 形状照 U3 的 events tab，差异只在投影面（SDL `AdminCourse` / `AdminCourseDetail`）：
 * - Course 无 venue / 押金槽位 / 主理人 / 挂载来源标记（Event-only 字段）——
 *   高危确认因此只覆盖定价槽位，无主理人与挂载来源区；
 * - 详情多一个 `provisionalTitle` 标记：占位标题是发布前置门，列表与详情都标黄；
 * - 对账跳转落点 = `/admin/courses?entity_id=<uuid>`（U3 已在 reconciliation 侧建好链接）。
 *
 * KTD4（session-settled）取数纪律：
 * - 列表不回读展示投影列；**权威计数只在 `fetchAdminCourse` 现取**，
 *   详情展开与高危确认（关定价槽位 / 取消课程）共用这一口。
 * - `confirmedCount` / `paymentPendingCount` 为 `null` = 计数不可用（不是 0）：
 *   渲染不可用态、禁用依赖它的入口，绝不落假值。
 * - 高危确认的笔数单一来源 = 打开确认时现取一次：取数中渲染 loading、
 *   取不到渲染不可用态；写成功后重取刷新（详情重载 + 列表重取）。
 * - 待付 > 200（批量免缴上限）时关槽位入口隐藏，引导走「取消课程」。
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
	adminCancelCourse,
	adminCloseCourse,
	adminLaunchCourse,
	adminUpdateCourse,
	fetchAdminCourse,
	fetchAdminCourses,
	fetchReconciliationFindings,
	fetchWorkspaces,
	type AdminCourseFilters,
} from "@/lib/admin";
import { copyText } from "@/lib/clipboard";
import { formatDateTime, fromLocalInput, toLocalInput } from "@/lib/format";
import { localizedUrl } from "@/lib/seo";
import {
	OFFERING_STATUS_CLASS,
	OFFERING_STATUS_VALUES,
	OFFERING_VISIBILITY_VALUES,
	RECONCILIATION_ENTITY_LABEL,
	RECONCILIATION_RULE_LABEL,
	type AdminCourse,
	type AdminCourseDetail,
	type AdminCoursePayload,
	type AdminCourseUpdateInput,
	type AdminReconciliationFinding,
	type AdminWorkspace,
} from "@/lib/graphql/admin";
import type { MutationError } from "@/lib/graphql/shared";

const PAGE_SIZE = 20;

/**
 * 批量免缴上限（`waive_pending_on_fee_slot_disable.ex` 超限整笔回滚）：
 * 待付笔数超此值时治理面不提供关槽位入口，引导走 cancel。
 */
const WAIVE_PENDING_LIMIT = 200;

/** 展开详情的取数状态：`unavailable` 同时覆盖「加载失败」与「id 不存在」，界面区分文案 */
type DetailState =
	| { status: "loading" }
	| { status: "ready"; course: AdminCourseDetail }
	| { status: "unavailable" };

/** 权威计数现取结果（`null` 计数 = 不可用，不是 0） */
type Counts =
	| { status: "ready"; confirmed: number | null; pending: number | null }
	| { status: "unavailable" }
	| { status: "notfound" };

/** 元数据编辑草稿（datetime-local 原值；未提交前不动详情真值） */
interface EditDraft {
	title: string;
	description: string;
	startsAt: string;
	endsAt: string;
	registrationDeadline: string;
	capacity: string;
	visibility: string;
	pricingEnabled: boolean;
}

function draftFromCourse(course: AdminCourseDetail): EditDraft {
	return {
		title: course.title,
		description: course.description ?? "",
		startsAt: toLocalInput(course.startsAt),
		endsAt: toLocalInput(course.endsAt),
		registrationDeadline: toLocalInput(course.registrationDeadline),
		capacity: course.capacity == null ? "" : String(course.capacity),
		visibility: course.visibility,
		pricingEnabled: course.pricingEnabled,
	};
}

type DraftDiff =
	| {
			ok: true;
			/** 只含**本次真变更**的键（同值重发会误写定价槽位决定，且分钟精度会截断秒） */
			input: AdminCourseUpdateInput;
			/** 本次提交会关停定价槽位（true→false）——高危确认的触发条件 */
			closesPricing: boolean;
	  }
	| { ok: false; issue: "title" | "capacity" };

/**
 * 草稿 vs 服务端快照 → 治理 update 输入。
 *
 * 时间字段用 `toLocalInput(服务端值) === 草稿` 判脏：datetime-local 只到分钟，
 * 未改动不下发，避免把库里的秒截断（workbench 表单同款脏检查纪律）。
 * 简介按去空白比较：只差首尾空白不算变更；清空下发 `null`（= 清掉该列），
 * 不下发空串（SDL `description` 的 nil 语义是「无简介」）。
 */
function diffDraft(draft: EditDraft, course: AdminCourseDetail): DraftDiff {
	const title = draft.title.trim();
	if (title === "") return { ok: false, issue: "title" };

	const capacityRaw = draft.capacity.trim();
	let capacity = course.capacity ?? null;
	if (capacityRaw !== "") {
		const parsed = Number(capacityRaw);
		if (!Number.isInteger(parsed) || parsed <= 0) return { ok: false, issue: "capacity" };
		capacity = parsed;
	}

	const description = draft.description.trim();
	const serverDescription = (course.description ?? "").trim();

	const input: AdminCourseUpdateInput = {};
	if (title !== course.title) input.title = title;
	if (description !== serverDescription) {
		input.description = description === "" ? null : description;
	}
	if (capacity !== (course.capacity ?? null)) input.capacity = capacity;
	if (draft.startsAt !== toLocalInput(course.startsAt)) {
		input.startsAt = fromLocalInput(draft.startsAt);
	}
	if (draft.endsAt !== toLocalInput(course.endsAt)) {
		input.endsAt = fromLocalInput(draft.endsAt);
	}
	if (draft.registrationDeadline !== toLocalInput(course.registrationDeadline)) {
		input.registrationDeadline = fromLocalInput(draft.registrationDeadline);
	}
	if (draft.visibility !== course.visibility) input.visibility = draft.visibility;
	if (course.pricingEnabled !== draft.pricingEnabled) {
		input.pricingEnabled = draft.pricingEnabled;
	}

	return { ok: true, input, closesPricing: input.pricingEnabled === false };
}

/**
 * 定价槽位开关（KTD4 的「关槽位入口」）：
 * - 槽位当前为开、待付 > 200（批量免缴上限）→ **隐藏入口**，引导走 cancel；
 * - 槽位当前为开、计数不可用（null）→ 入口禁用，不给基于假 0 的关停机会；
 * - 槽位当前为关 → 任意切换（开启无批量免缴后果，不受计数约束）。
 */
function FeeSlotField({
	label,
	enabled,
	pendingCount,
	checked,
	onChange,
}: {
	label: string;
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
				<p className="admin-muted">{t("courseSlotEntryHidden", { count: pendingCount ?? 0 })}</p>
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
				<p className="admin-muted">{t("courseSlotEntryDisabled")}</p>
			) : null}
		</div>
	);
}

export default function AdminCoursesPage() {
	return (
		// Next.js 16：useSearchParams（对账跳转落点 ?entity_id=）需包 Suspense 边界（issue #73）
		<Suspense fallback={<p className="admin-muted">…</p>}>
			<AdminCoursesContent />
		</Suspense>
	);
}

function AdminCoursesContent() {
	const t = useTranslations("admin");
	const labelsT = useTranslations();
	const errorT = useTranslations("errors");
	const locale = useLocale();
	const searchParams = useSearchParams();
	/** 对账页跳转落点（R3/AE4）：/admin/courses?entity_id=<uuid> 定位并自动展开该行 */
	const targetEntityId = searchParams?.get("entity_id") ?? null;

	// ---- 列表 ----
	const [rows, setRows] = useState<AdminCourse[] | null>(null);
	const [listError, setListError] = useState(false);
	const [loading, setLoading] = useState(false);
	const [search, setSearch] = useState("");
	const [status, setStatus] = useState("");
	const [workspaceId, setWorkspaceId] = useState("");
	const [applied, setApplied] = useState<AdminCourseFilters>({});
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
		courseId: string;
		input: AdminCourseUpdateInput;
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

	const loadList = useCallback((filters: AdminCourseFilters, after: number) => {
		const seq = ++listSeqRef.current;
		// .then/.catch 链（users 页模式）：effect 内调用不触发 set-state-in-effect
		return fetchAdminCourses(filters, { first: PAGE_SIZE, after: String(after) })
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
		void fetchAdminCourse(id)
			.then((course) => {
				if (detailSeqRef.current !== seq) return;
				setExpand((current) =>
					current?.id === id
						? { id, state: course ? { status: "ready", course } : { status: "unavailable" } }
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
		void fetchReconciliationFindings({ entityType: "course", entityId: id })
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

	const expandedCourse = expand?.state.status === "ready" ? expand.state.course : null;
	/** 对账定位行：不在当前列表里也要可见（否则跳转落空） */
	const visibleRows = useMemo(() => {
		if (!expandedCourse) return rows;
		const list = rows ?? [];
		if (list.some((row) => row.id === expandedCourse.id)) return rows;
		return [expandedCourse, ...list];
	}, [rows, expandedCourse]);
	const pinnedOutsideList =
		expandedCourse !== null && rows !== null && !rows.some((row) => row.id === expandedCourse.id);
	const currentFindings = findings && expand && findings.id === expand.id ? findings : null;
	/** KTD4：计数一律按「null/undefined = 不可用」归一，绝不落假 0 */
	const confirmedCount = expandedCourse?.confirmedCount ?? null;
	const pendingCount = expandedCourse?.paymentPendingCount ?? null;

	/** 写失败文案：稳定 code（如 course_slug_locked）走 errors 命名空间本地化，其余回落后端 message */
	function mutationErrorText(errors: MutationError[]): string {
		const failure = errors[0];
		if (!failure) return t("courseSaveFailed");
		if (failure.code && errorT.has(failure.code)) return errorT(failure.code);
		return failure.message || t("courseSaveFailed");
	}

	/**
	 * 权威计数现取（KTD4）：详情与确认弹窗共用。
	 * id 不存在单独成态——不把它混进「计数不可用」，避免用户对着已不存在的实体操作。
	 */
	async function fetchCounts(id: string): Promise<Counts> {
		try {
			const course = await fetchAdminCourse(id);
			if (!course) return { status: "notfound" };
			return {
				status: "ready",
				confirmed: course.confirmedCount ?? null,
				pending: course.paymentPendingCount ?? null,
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
		run: () => Promise<AdminCoursePayload>,
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
			setHint(t("courseSaved"));
			refreshAfterWrite(id);
		} catch {
			// 传输层 / 顶层 GraphQL 错误（unauthorized/forbidden/5xx）：必须可见，不静默
			setActionError(t("courseSaveFailedNetwork"));
		} finally {
			setBusy(null);
		}
	}

	function toggleDetail(row: AdminCourse) {
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
		const next: AdminCourseFilters = {
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
	 * 取消课程（不可逆）：确认前现取权威计数并披露受影响笔数；
	 * 取不到数字时如实披露「不可用」，既不落假 0 也不省略二次确认。
	 */
	async function cancelCourse(row: AdminCourse) {
		setBusy(row.id);
		setActionError(null);
		setHint(null);
		const counts = await fetchCounts(row.id);
		if (counts.status === "notfound") {
			setBusy(null);
			setActionError(t("courseNotFound"));
			return;
		}
		const message =
			counts.status === "ready" && counts.confirmed !== null && counts.pending !== null
				? t("courseCancelConfirm", {
						title: row.title,
						confirmed: counts.confirmed,
						pending: counts.pending,
					})
				: t("courseCancelConfirmUnavailable", { title: row.title });
		setBusy(null);
		if (!window.confirm(message)) return;
		await runMutation(row.id, () => adminCancelCourse(row.id));
	}

	function saveMetadata() {
		if (expand?.state.status !== "ready" || !draft) return;
		const course = expand.state.course;
		const diff = diffDraft(draft, course);
		if (!diff.ok) {
			setHint(null);
			setActionError(
				diff.issue === "title" ? t("courseTitleRequired") : t("courseCapacityInvalid"),
			);
			return;
		}
		if (Object.keys(diff.input).length === 0) {
			setActionError(null);
			setHint(t("courseNoChanges"));
			return;
		}
		setActionError(null);
		setHint(null);
		if (diff.closesPricing) {
			// 关槽位有级联财务后果（批量免缴）→ 先过确认弹层，不直写
			requestSlotSave(course.id, diff.input);
			return;
		}
		void runMutation(course.id, () => adminUpdateCourse(course.id, diff.input));
	}

	/** 打开关定价槽位确认：数字单一来源 = 此刻现取一次（弹层内渲染 loading / 不可用态） */
	function requestSlotSave(courseId: string, input: AdminCourseUpdateInput) {
		setSlotConfirm({ courseId, input, counts: { status: "loading" } });
		void fetchCounts(courseId).then((counts) => {
			setSlotConfirm((current) =>
				current && current.courseId === courseId ? { ...current, counts } : current,
			);
		});
	}

	function confirmSlotSave() {
		if (!slotConfirm) return;
		const { courseId, input } = slotConfirm;
		setSlotConfirm(null);
		void runMutation(courseId, () => adminUpdateCourse(courseId, input));
	}

	async function copyLink(row: AdminCourse) {
		if (!row.slug) return;
		const ok = await copyText(localizedUrl(`/courses/${row.slug}`, locale));
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
					<h1>{t("coursesTitle")}</h1>
					<p className="admin-page__desc">{t("coursesDesc")}</p>
				</div>
			</div>

			<div className="admin-toolbar">
				<input
					value={search}
					onChange={(e) => setSearch(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && applyFilters()}
					placeholder={t("courseSearchPlaceholder")}
					aria-label={t("courseSearchAria")}
					className="l-input"
				/>
				<select
					value={status}
					onChange={(e) => setStatus(e.target.value)}
					aria-label={t("courseStatusAria")}
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
					aria-label={t("courseWorkspaceAria")}
					className="l-input"
				>
					<option value="">{t("courseWorkspaceAll")}</option>
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
				// 列表读失败且无对账定位行：只留上面的错误提示，不落「暂无课程」假空态
				listError ? null : <p className="admin-empty">{t("coursesEmpty")}</p>
			) : (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("courseTitle")}</th>
								<th>{t("initiativeSlug")}</th>
								<th>{t("initiativeStatus")}</th>
								<th className="admin-table__num">{t("courseCapacity")}</th>
								<th>{t("courseWorkspace")}</th>
								<th>{t("courseStartsAt")}</th>
								<th className="admin-table__actions">{t("initiativeAction")}</th>
							</tr>
						</thead>
						<tbody>
							{visibleRows.map((row) => {
								const expanded = expand?.id === row.id;
								const detailState = expanded ? expand?.state ?? null : null;
								const workspace = workspaceName(row.workspaceId);
								const publicUrl = row.slug
									? localizedUrl(`/courses/${row.slug}`, locale)
									: null;
								return (
									<Fragment key={row.id}>
										<tr>
											<td>
												<span className="admin-table__primary">{row.title}</span>
												{/* 占位标题 = 发布前置门（后端守卫）：治理列表标黄，一眼可辨 */}
												{row.provisionalTitle ? (
													<span className="admin-table__sub">
														<span className="l-badge l-badge-pending">
															{t("courseProvisionalTitle")}
														</span>
													</span>
												) : null}
												{pinnedOutsideList && expandedCourse?.id === row.id ? (
													<span className="admin-table__sub">
														{t("coursePinnedHint")}
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
												{row.capacity ?? t("courseCapacityUnlimited")}
											</td>
											<td>
												{workspace ?? <span className="l-mono">{row.workspaceId}</span>}
											</td>
											<td>
												<div>{`${t("courseStartsAt")}：${formatDateTime(row.startsAt)}`}</div>
												<div className="admin-muted">{`${t("courseDeadline")}：${formatDateTime(
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
													{expanded ? t("courseDetailHide") : t("courseDetail")}
												</button>
												{/* 按钮可见性矩阵（KTD6）：draft 只有发布；open 有结束 + 取消；终态无出边 */}
												{row.status === "draft" ? (
													<button
														type="button"
														className="l-btn-outline"
														disabled={busy === row.id}
														onClick={() =>
															void runMutation(row.id, () => adminLaunchCourse(row.id))
														}
													>
														{t("courseLaunch")}
													</button>
												) : null}
												{row.status === "open" ? (
													<>
														<button
															type="button"
															className="l-btn-outline"
															disabled={busy === row.id}
															onClick={() =>
																void runMutation(row.id, () => adminCloseCourse(row.id))
															}
														>
															{t("courseClose")}
														</button>
														<button
															type="button"
															className="l-btn-outline l-btn-outline--danger"
															disabled={busy === row.id}
															onClick={() => void cancelCourse(row)}
														>
															{t("courseCancel")}
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
															{t("courseDetailUnavailable")}
														</p>
													) : expandedCourse ? (
														<div className="admin-card admin-card__body">
															<h3 className="admin-section-title">
																{t("courseBasic")}
															</h3>
															{/* 占位标题标记（U4 投影差异）：发布前置门，展开即醒目 */}
															{expandedCourse.provisionalTitle ? (
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("courseTitle")}
																	</span>
																	<span className="l-badge l-badge-pending">
																		{t("courseProvisionalTitle")}
																	</span>
																	<span className="admin-field__hint">
																		{t("courseProvisionalTitleHint")}
																	</span>
																</div>
															) : null}
															<div className="admin-form">
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("coursePublicLink")}
																	</span>
																	{publicUrl && expandedCourse.slug ? (
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
																				onClick={() => void copyLink(expandedCourse)}
																			>
																				{copiedId === expandedCourse.id
																					? t("initiativeLinkCopied")
																					: t("initiativeCopyLink")}
																			</button>
																		</span>
																	) : (
																		<span className="admin-muted">
																			{t("courseSlugMissing")}
																		</span>
																	)}
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("initiativeStatus")}
																	</span>
																	<span
																		className={
																			OFFERING_STATUS_CLASS[expandedCourse.status] ??
																			"l-badge l-badge-muted"
																		}
																	>
																		{labelsT(
																			`labels.eventStatus.${expandedCourse.status}`,
																		)}
																	</span>
																	<span className="admin-muted">
																		{labelsT(
																			`labels.visibility.${expandedCourse.visibility}`,
																		)}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("courseWorkspace")}
																	</span>
																	<span>
																		{workspaceName(expandedCourse.workspaceId) ?? (
																			<span className="l-mono">
																				{expandedCourse.workspaceId}
																			</span>
																		)}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("courseStartsAt")}
																	</span>
																	<span>
																		{`${formatDateTime(expandedCourse.startsAt)} → ${formatDateTime(
																			expandedCourse.endsAt,
																		)}`}
																	</span>
																	<span className="admin-field__hint">
																		{`${t("courseDeadline")}：${formatDateTime(
																			expandedCourse.registrationDeadline,
																		)}`}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("courseDescription")}
																	</span>
																	<span
																		className={
																			expandedCourse.description ? undefined : "admin-muted"
																		}
																	>
																		{expandedCourse.description ||
																			t("courseDescriptionEmpty")}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("courseCapacity")}
																	</span>
																	<span>
																		{expandedCourse.capacity ??
																			t("courseCapacityUnlimited")}
																	</span>
																</div>
																<div className="admin-field">
																	<span className="admin-field__label">
																		{t("courseConfirmedCount")}
																	</span>
																	{/* KTD4：null = 计数不可用，不落假值 */}
																	<span
																		className={
																			confirmedCount === null ? "admin-muted" : undefined
																		}
																	>
																		{confirmedCount === null
																			? t("courseCountsUnavailable")
																			: confirmedCount}
																	</span>
																	<span className="admin-field__hint">
																		{`${t("coursePendingCount")}：${
																			pendingCount === null
																				? t("courseCountsUnavailable")
																				: pendingCount
																		}`}
																	</span>
																</div>
															</div>

															<h3 className="admin-section-title">
																{t("courseFindings")}
															</h3>
															{currentFindings?.failed ? (
																<p className="admin-alert admin-alert--error">
																	{t("courseFindingsUnavailable")}
																</p>
															) : currentFindings?.list ? (
																currentFindings.list.length === 0 ? (
																	<p className="admin-muted">
																		{t("courseFindingsEmpty")}
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
																		{t("courseEditMetadata")}
																	</h3>
																	<div className="admin-form">
																		<div className="admin-field">
																			<label
																				htmlFor="course-detail-slug"
																				className="admin-field__label"
																			>
																				{t("initiativeSlug")}
																			</label>
																			{/* slug 治理面只读展示：已发布实体的 slug 改动由后端
																			    `course_slug_locked` 拒绝（R7/AE5） */}
																			<input
																				id="course-detail-slug"
																				className="l-input"
																				value={expandedCourse.slug ?? ""}
																				readOnly
																			/>
																			{expandedCourse.status !== "draft" ? (
																				<p className="admin-muted">
																					{t("initiativeSlugLocked")}
																				</p>
																			) : null}
																		</div>
																		<div className="admin-field">
																			<label
																				htmlFor="course-detail-title"
																				className="admin-field__label"
																			>
																				{t("courseTitle")}
																			</label>
																			<input
																				id="course-detail-title"
																				className="l-input"
																				value={draft.title}
																				onChange={(e) =>
																					setDraft({ ...draft, title: e.target.value })
																				}
																			/>
																		</div>
																		<div className="admin-field">
																			<label
																				htmlFor="course-detail-description"
																				className="admin-field__label"
																			>
																				{t("courseDescription")}
																			</label>
																			<textarea
																				id="course-detail-description"
																				className="l-input"
																				rows={3}
																				value={draft.description}
																				onChange={(e) =>
																					setDraft({
																						...draft,
																						description: e.target.value,
																					})
																				}
																			/>
																		</div>
																		<div className="admin-field">
																			<label
																				htmlFor="course-detail-starts"
																				className="admin-field__label"
																			>
																				{t("courseStartsAt")}
																			</label>
																			<input
																				id="course-detail-starts"
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
																				htmlFor="course-detail-ends"
																				className="admin-field__label"
																			>
																				{t("courseEndsAt")}
																			</label>
																			<input
																				id="course-detail-ends"
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
																				htmlFor="course-detail-deadline"
																				className="admin-field__label"
																			>
																				{t("courseDeadline")}
																			</label>
																			<input
																				id="course-detail-deadline"
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
																				htmlFor="course-detail-capacity"
																				className="admin-field__label"
																			>
																				{t("courseCapacity")}
																			</label>
																			<input
																				id="course-detail-capacity"
																				className="l-input"
																				value={draft.capacity}
																				placeholder={t("courseCapacityUnlimited")}
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
																				htmlFor="course-detail-visibility"
																				className="admin-field__label"
																			>
																				{t("courseVisibility")}
																			</label>
																			<select
																				id="course-detail-visibility"
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
																			label={t("coursePricingSlot")}
																			enabled={expandedCourse.pricingEnabled}
																			pendingCount={pendingCount}
																			checked={draft.pricingEnabled}
																			onChange={(next) =>
																				setDraft({ ...draft, pricingEnabled: next })
																			}
																		/>
																		<div>
																			<button
																				type="button"
																				className="l-btn-primary"
																				disabled={busy === expandedCourse.id}
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
																		setDraft(draftFromCourse(expandedCourse));
																	}}
																>
																	{t("courseEditMetadata")}
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
					aria-label={t("courseSlotImpactTitle")}
					className="admin-modal-overlay"
					onClick={() => setSlotConfirm(null)}
				>
					<div className="admin-modal" onClick={(e) => e.stopPropagation()}>
						<h2>{t("courseSlotImpactTitle")}</h2>
						<p>{t("courseSlotImpactSlot")}</p>
						{slotCounts === null || slotCounts.status === "loading" ? (
							<p className="admin-muted">{t("courseSlotCountsLoading")}</p>
						) : slotPending === null ? (
							// KTD4：取不到数字 → 不可用态，不落假值，确认保持禁用
							<p className="admin-alert admin-alert--warn">
								{t("courseSlotCountsUnavailable")}
							</p>
						) : slotOverLimit ? (
							<p className="admin-alert admin-alert--warn">
								{t("courseSlotImpactLimit", { count: slotPending })}
							</p>
						) : (
							<>
								<p>{t("courseSlotImpactBody", { count: slotPending })}</p>
								<p className="admin-muted">{t("courseSlotImpactNote")}</p>
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
								{t("courseSlotConfirm")}
							</button>
						</div>
					</div>
				</div>
			) : null}
		</section>
	);
}
