"use client";
import { useEffect, useRef, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { cancelInitiative, closeInitiative, createInitiative, fetchInitiative, fetchInitiatives, openInitiative, updateInitiative, upsertInitiativeRule } from "@/lib/admin";
import { copyText } from "@/lib/clipboard";
import { localizedUrl } from "@/lib/seo";
import { formatDateTime } from "@/lib/format";
import { formatVenue, parseVenue } from "@/lib/public-offerings";
import {
	INITIATIVE_STATUS_CLASS,
	type AdminInitiative,
	type AdminInitiativeMountedEvent,
	type AdminInitiativeRule,
} from "@/lib/graphql/admin";
import type { MutationError } from "@/lib/graphql/shared";

const RULE_KEYS = ["deposit", "age_gate", "min_participants", "deadline_rule"] as const;

/**
 * 规则变更影响预览的数字（#595）：全部由已加载的挂载场清单本地推导——
 * 与操作者同屏看到的行同源，不引入第二处计数真源。
 *
 * 口径（#641 对齐 #587 守卫）：`total` / `pricingBlocked` 只数非终态场
 * （draft / open，即后端 `lock_propagatable_events/1` 的传播范围）——终态场的
 * 定价不可能触发 `event_payment_mode_exclusive`，计入只会把管理员指去处理一个
 * 不会造成拒绝的场。`terminal`（closed / cancelled）与 `confirmed`
 * （events.confirmed_count 投影；权威计数在名额账本，可能滞后一拍）仍是
 * 全量事实分组，与 total 的传播范围口径刻意不同。
 *
 * 两处计数刻意不同是**有意设计**，不要为了「一致」把它们统一：弹层
 * total = 非终态传播范围；表头「挂载场（N）」= `mounts.length` 全量挂载
 * （Mounts.list 如实投影全状态，表格也展示全部行）。
 */
function mountedImpact(mounts: AdminInitiativeMountedEvent[]) {
	// 单趟计数（每次 render 都会重算，不留只为读 .length 的中间数组）。
	// `propagatable` 命名对齐后端 `lock_propagatable_events/1`——不用 `active`：
	// 仓库里 active 一贯指报名/订单「进行中」，且活动侧与场次侧两条状态轴
	// 刻意不复刻（rule_inheritance.ex moduledoc），别让词形暗示可互推。
	let draft = 0;
	let open = 0;
	let terminal = 0;
	let confirmed = 0;
	let pricingBlocked = 0;
	for (const mount of mounts) {
		const propagatable = mount.status === "draft" || mount.status === "open";
		if (mount.status === "draft") draft += 1;
		else if (mount.status === "open") open += 1;
		else terminal += 1;
		if (propagatable && mount.pricingEnabled) pricingBlocked += 1;
		confirmed += mount.confirmedCount ?? 0;
	}
	return {
		total: draft + open,
		draft,
		open,
		terminal,
		confirmed,
		pricingBlocked,
	};
}

/** 丢弃某规则的本地草稿（受控 textarea 因此回到已存值）。取消变更的唯一副作用。 */
function withoutDraft(drafts: Record<string, string>, key: string): Record<string, string> {
	const next = { ...drafts };
	delete next[key];
	return next;
}

/** 从 MutationError.fields 取 `event_id=<uuid>` 的值（#595 拒绝路径定位用）。 */
function errorEventId(fields?: string[] | null): string | null {
	for (const field of fields ?? []) {
		if (field.startsWith("event_id=")) return field.slice("event_id=".length);
	}
	return null;
}

export default function AdminInitiativesPage() {
	const t = useTranslations("admin");
	const labelsT = useTranslations();
	const errorT = useTranslations("errors");
	const locale = useLocale();
	const [rows, setRows] = useState<AdminInitiative[] | null>(null);
	const [error, setError] = useState(false);
	const [actionError, setActionError] = useState<string | null>(null);
	const [busy, setBusy] = useState<string | null>(null);
	const [copiedId, setCopiedId] = useState<string | null>(null);
	const [form, setForm] = useState({ name: "", slug: "", description: "" });
	const [editing, setEditing] = useState<string | null>(null);
	const [rules, setRules] = useState<AdminInitiativeRule[]>([]);
	const [rulesLoadedFor, setRulesLoadedFor] = useState<string | null>(null);
	/**
	 * #595 挂载场清单（随 getInitiative 一次到达；影响预览的唯一数字来源）。
	 * `null` = 附挂读面加载失败（与「真的没有挂载场」= `[]` 区分开，不把失败伪装成 0 场）。
	 */
	const [mounts, setMounts] = useState<AdminInitiativeMountedEvent[] | null>(null);
	/** 规则 textarea 的本地草稿（受控）：取消变更 = 删草稿回到已存值 */
	const [ruleDrafts, setRuleDrafts] = useState<Record<string, string>>({});
	/** 锁死开关的受控态：确认前不动真值，取消即无痕 */
	const [ruleLocks, setRuleLocks] = useState<Record<string, boolean>>({});
	/**
	 * 各规则 key 的在途写入计数（N2）：用计数器而非标量 busy——
	 * 单标量会被"任意一次写入的 finally / 离开编辑态"清零，导致在途写仍在飞时
	 * 「编辑」重新可点，读可能早于写发出却晚于写落地，把旧快照盖到面板上。
	 * 本计数**不随离开编辑态清零**（在途写尚未落定，仍要挡住重新进入）。
	 */
	const [busyKeys, setBusyKeys] = useState<Record<string, number>>({});
	/** 待确认的锁死规则变更（非空 = 影响预览弹层打开） */
	const [pendingRule, setPendingRule] = useState<{ key: string; valueJson: string } | null>(null);
	/**
	 * 当前正在编辑的 Initiative（异步回包的落点守卫，A1）：离开/切换编辑态时置空，
	 * 迟到的回包不再写进另一个 Initiative 的面板（四个规则 key 全局同名，只按 key
	 * 合并会把上一场的规则/锁死态盖到当前场）。
	 */
	const editingRef = useRef<string | null>(null);
	/**
	 * 详情读请求序号（F4 判据 A / N3）：`loadInitiative` 与 `refreshMounts` 共用
	 * 同一个序号，"最后一次发出的读胜出"，任何更旧的 load / refresh 回包都丢弃。
	 */
	const loadSeqRef = useRef(0);
	/** 各规则 key 的写入序号（N1）：只有该 key 最新一次写入的回包可以回填/清草稿 */
	const writeSeqRef = useRef<Record<string, number>>({});
	/**
	 * 各规则 key 的**锁死意图**（N7）：`ruleLocks` 只在写入成功回包时更新，在途期间
	 * 读它拿到的是旧值——期间发生的 blur 提交会把用户的锁死意图翻回去。意图在
	 * `submitRule` 里同步记账（唯一写入口），离开/重载编辑态时清空。
	 */
	const lockIntentRef = useRef<Record<string, boolean>>({});
	/** 弹层焦点约束（F6/N4）：两个按钮 ref + 打开即聚焦，Tab 不得回到背后面板 */
	const cancelButtonRef = useRef<HTMLButtonElement | null>(null);
	const confirmButtonRef = useRef<HTMLButtonElement | null>(null);
	const mountList = mounts ?? [];
	const impact = mountedImpact(mountList);
	const writesInFlight = Object.values(busyKeys).reduce((sum, count) => sum + count, 0);
	/** 在途写计数增减（到 0 时删键，避免残留） */
	function bumpBusy(key: string, delta: number) {
		setBusyKeys((current) => {
			const next = { ...current, [key]: Math.max(0, (current[key] ?? 0) + delta) };
			if (next[key] === 0) delete next[key];
			return next;
		});
	}
	/** 该规则当前生效的锁死意图（N7）：有在途/刚提交的意图则用它，否则用渲染态 */
	function intendedLocked(key: string, renderedLocked: boolean): boolean {
		return lockIntentRef.current[key] ?? renderedLocked;
	}
	/**
	 * slug 锁定（#588）：Initiative 发布（open / closed）后公开 URL 段不可改，
	 * 与后端 `Initiative :update` 守卫同口径（非 draft 即锁）。status 单源是
	 * `rows`（`fetchInitiative` 只补 rules），不用 form state 缓存。
	 */
	const editingRow = editing ? rows?.find((row) => row.id === editing) ?? null : null;
	const slugLocked = editingRow !== null && editingRow.status !== "draft";

	function firstError(payload: { errors: MutationError[] }): string {
		return payload.errors[0]?.message ?? t("loadFailed");
	}
	/**
	 * 规则写入失败的呈现（#595 D4）：后端 `fields` 里的 `event_id=<uuid>` 用
	 * 已加载的挂载场翻成「场 + 工作台」，让管理者知道去哪一场处理；翻不到时
	 * 退化为只显示 id。
	 *
	 * 文案：已知 code → errors 命名空间本地化；未知 code（如 `invalid_input`——
	 * 它是 web 契约层字面量、按 #241 不得进 domain 契约，故无 errors 文案）→
	 * 页面兜底文案，**不透传英文原文**（同 usePaymentErrorTranslator 的纪律）。
	 */
	function ruleErrorMessage(errors: MutationError[]): string {
		const failure = errors[0];
		// N11：mutation resolve 出 null/空 errors（lib/admin.ts 的兜底形状）也是"没保存成功"，
		// 不得落回"页面加载失败"的文案
		if (!failure) return t("initiativeRuleSaveFailedNetwork");
		const message = failure.code && errorT.has(failure.code)
			? errorT(failure.code)
			: t("initiativeRuleSaveFailed");
		const eventId = errorEventId(failure.fields);
		if (!eventId) return message;
		const mount = mountList.find((item) => item.id === eventId);
		return mount
			? t("initiativeRuleErrorEvent", { event: mount.title, workspace: mount.workspaceName, message })
			: t("initiativeRuleErrorEventId", { eventId, message });
	}
	/** 离开编辑态：规则草稿/锁死态/挂载场/待确认弹层/上一条告警一并清空 */
	function resetRuleEditing() {
		editingRef.current = null;
		setRules([]);
		setRulesLoadedFor(null);
		setMounts(null);
		setRuleDrafts({});
		setRuleLocks({});
		setPendingRule(null);
		setActionError(null);
		lockIntentRef.current = {};
		// N2：**不**清 busyKeys——在途写尚未落定，「编辑」必须继续保持禁用
	}
	function loadInitiative(id: string) {
		editingRef.current = id;
		const seq = ++loadSeqRef.current;
		void fetchInitiative(id).then((details) => {
			// F4 判据 A：非最新一次读（同 id 连点）或已离开编辑态 → 回包不落地
			if (editingRef.current !== id || loadSeqRef.current !== seq) return;
			if (!details) {
				// 详情不存在（列表与详情之间被删）：不进编辑态——否则会对着四条空规则面板
				// 写入（checkbox 不受 rule 存在性约束），相当于凭幻觉落库
				setActionError(t("loadFailed"));
				return;
			}
			const loaded = details.rules ?? [];
			lockIntentRef.current = {};
			setRules(loaded);
			setRuleLocks(Object.fromEntries(loaded.map((item) => [item.key, item.locked])));
			// null / undefined = 附挂读面失败（不伪装成 0 场）；[] 才是真空清单
			setMounts(details.mountedEvents ?? null);
			setRuleDrafts({});
			setRulesLoadedFor(id);
		}).catch(() => {
			// 详情读失败（网络 / 附挂读面之外的 schema 错误）必须可见，不能只留一个空面板
			if (editingRef.current === id && loadSeqRef.current === seq) {
				setActionError(t("loadFailed"));
			}
		});
	}
	/** 锁死写入会传播到全部挂载场（改写押金/年龄/成班/截止列）→ 重拉清单，否则「事后核对」是过期快照 */
	function refreshMounts(initiativeId: string) {
		// N3：与 loadInitiative 共用同一个读序号——"最后一次发出的读胜出"，
		// 更旧的 refresh（或其 catch → 清单不可用）不得覆盖更新的 load / refresh
		const seq = ++loadSeqRef.current;
		void fetchInitiative(initiativeId).then((details) => {
			if (editingRef.current !== initiativeId || loadSeqRef.current !== seq) return;
			if (details) setMounts(details.mountedEvents ?? null);
		}).catch(() => {
			// 刷新失败不掩盖"写入已成功"的事实；改为如实显示清单不可用
			if (editingRef.current === initiativeId && loadSeqRef.current === seq) setMounts(null);
		});
	}
	function draftValue(key: string, rule?: AdminInitiativeRule): string {
		return ruleDrafts[key] ?? rule?.valueJson ?? "{}";
	}
	/**
	 * 规则写入唯一出口。锁死变更必须先过确认弹层（见 requestRuleChange）；
	 * `locked` 用入参而非 rule.locked：同一 key 的锁死开关与值可能同批变更。
	 */
	function submitRule(initiativeId: string, key: string, valueJson: string, locked: boolean) {
		lockIntentRef.current[key] = locked;
		const seq = (writeSeqRef.current[key] ?? 0) + 1;
		writeSeqRef.current[key] = seq;
		bumpBusy(key, 1);
		setActionError(null);
		void upsertInitiativeRule(initiativeId, key, valueJson, locked).then((result) => {
			// 已切走（切到别的 Initiative 或退出编辑态）→ 迟到的回包不落到当前面板
			if (editingRef.current !== initiativeId) return;
			// N1：该 key 已有更新的写入发出 → 旧回包不回填（避免响应乱序时"旧值盖新值"）
			if (writeSeqRef.current[key] !== seq) return;
			if (result.result) {
				const saved = result.result;
				setRules((current) => current.map((item) => item.key === key ? { ...item, ...saved } : item));
				// F4（第五轮）：锁死态取服务器的回显值（同 payload），而不是请求值
				setRuleLocks((current) => ({ ...current, [key]: saved.locked }));
				// N1：只有草稿仍等于本次提交的值时才清——在途期间重新输入的新值必须保留，
				// 否则受控 textarea 会被回包拉回旧值，新编辑既不在 state 也无从提交
				setRuleDrafts((current) => (current[key] === valueJson ? withoutDraft(current, key) : current));
				if (locked) refreshMounts(initiativeId);
			} else {
				// F3（第五轮）：写入被拒 → 撤掉意图，让服务器真值（ruleLocks）重新主导后续 blur；
				// 否则被拒的 locked=true 会一直粘住，之后每次值编辑都再走锁死分支并被再拒
				delete lockIntentRef.current[key];
				setActionError(ruleErrorMessage(result.errors));
			}
		}).catch(() => {
			// 传输层 / 顶层 GraphQL 错误（unauthorized/forbidden/5xx）：必须可见，不静默
			if (editingRef.current !== initiativeId) return;
			// N9：与 then 同口径——旧写入的 rejection 不得在新写入成功之后才弹"未保存"
			if (writeSeqRef.current[key] !== seq) return;
			delete lockIntentRef.current[key];
			setActionError(t("initiativeRuleSaveFailedNetwork"));
		}).finally(() => {
			// N2：计数无条件回减（在途写落定就该释放门），但 busy 指示只在本面板还有效时更新
			bumpBusy(key, -1);
		});
	}
	/** 锁死规则需要显式确认；非锁死写入只改规则行（不影响已挂载场）→ 直写 */
	function requestRuleChange(key: string, valueJson: string, locked: boolean) {
		if (!editing) return;
		/**
		 * F1（第五轮）：唯一入口收口——弹层打开期间不接受任何新的规则变更请求。
		 * 容器 onBlur 与 checkbox onChange 都经由这里；只拦容器 blur 不够：确认按钮
		 * 处于 disabled（该 key 有在途写）时焦点不会被拉进弹层，背景 checkbox 仍可被
		 * Space 激活并触发这里，从而在弹层打开期间写出未确认变更。
		 */
		if (pendingRule) return;
		if (!locked) {
			setPendingRule((current) => (current?.key === key ? null : current));
			submitRule(editing, key, valueJson, false);
			return;
		}
		setActionError(null);
		setPendingRule({ key, valueJson });
	}
	/** 取消路径（按钮 / Escape / 遮罩同一出口）：关弹层 + 丢草稿，不发任何 mutation */
	function cancelRuleChange(key: string) {
		setRuleDrafts((current) => withoutDraft(current, key));
		setPendingRule(null);
	}
	function confirmRuleChange() {
		if (!pendingRule || !editing) return;
		const { key, valueJson } = pendingRule;
		setPendingRule(null);
		submitRule(editing, key, valueJson, true);
	}
	useEffect(() => {
		if (!pendingRule) return;
		const key = pendingRule.key;
		// F6/N4：弹层打开即把焦点收进弹层（aria-modal）；Tab 拦截放在 document 级——
		// 点在弹层正文（h2/p）会把焦点落到 body，挂在弹层元素上的 keydown 收不到，
		// 下一次 Tab 就会跑进背后面板。Escape 仍是同一取消出口。
		confirmButtonRef.current?.focus();
		function onKeyDown(event: KeyboardEvent) {
			if (event.key === "Escape") {
				setRuleDrafts((current) => withoutDraft(current, key));
				setPendingRule(null);
				return;
			}
			if (event.key !== "Tab") return;
			const first = cancelButtonRef.current;
			const last = confirmButtonRef.current;
			if (!first || !last) return;
			// F2（第五轮）：Tab **一律**拦截再重分配焦点。只拦部分分支会让默认 Tab 顺序
			// 把焦点带到弹层之后的背景控件（列表按钮不受写入在途约束）。N8：对 disabled
			// 按钮调 focus() 是空操作，所以目标一律取"当前可用"的那个。
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
			// 焦点已逃出弹层（如点了正文）→ 拉回，不放它进背后面板
			(confirmEnabled ? last : first).focus();
		}
		document.addEventListener("keydown", onKeyDown);
		return () => document.removeEventListener("keydown", onKeyDown);
	}, [pendingRule]);
	/**
	 * 复制公开详情页链接（运营投放出口，Patch 3）：与 sitemap / canonical 同源
	 * 的 `localizedUrl`（NEXT_PUBLIC_WEB_BASE_URL），非 window.location.origin——
	 * 后台域名与公开域名不一致时后者会拷出错误链接。
	 * 复制失败（非安全上下文 / 权限拒绝）保持原文案，不假装成功。
	 */
	async function copyLink(row: AdminInitiative) {
		const ok = await copyText(localizedUrl(`/initiatives/${row.slug}`, locale));
		if (!ok) return;
		setCopiedId(row.id);
		setTimeout(() => setCopiedId((current) => (current === row.id ? null : current)), 2000);
	}
	/**
	 * 生命周期迁移（#628）：draft → open / close 二选一；open → close（收尾，
	 * 不退款）或 cancel（中止，级联取消挂载场 + 全额退款）；终态无出边。
	 * 中止不可逆，二次确认口径与 MCP `admin_cancel_initiative` 的确认文案对齐。
	 */
	async function transition(row: AdminInitiative, action: "open" | "close" | "cancel") {
		if (action === "cancel" && !window.confirm(t("initiativeCancelConfirm", { name: row.name }))) return;
		setBusy(row.id);
		setActionError(null);
		const result =
			action === "open" ? await openInitiative(row.id)
			: action === "close" ? await closeInitiative(row.id)
			: await cancelInitiative(row.id);
		if (result?.result) setRows((current) => current?.map((item) => item.id === row.id ? { ...item, status: result.result?.status ?? item.status } : item) ?? null);
		else if (result) setActionError(firstError(result));
		setBusy(null);
	}
	async function save() {
		if (!form.name.trim() || !form.slug.trim()) return;
		setBusy("form");
		setActionError(null);
		const result = editing ? await updateInitiative(editing, form) : await createInitiative(form);
		if (result.result) {
			setRows((current) => editing ? current?.map((row) => row.id === editing ? { ...row, ...result.result } : row) ?? null : [...(current ?? []), result.result!]);
			setForm({ name: "", slug: "", description: "" });
			setEditing(null);
			resetRuleEditing();
		} else setActionError(firstError(result));
		setBusy(null);
	}
	useEffect(() => { let cancelled = false; void fetchInitiatives().then((value) => { if (!cancelled) setRows(value); }).catch(() => { if (!cancelled) setError(true); }); return () => { cancelled = true; }; }, []);
	return <section>
		<div className="admin-page__head">
			<div>
				<h1>{t("initiativesTitle")}</h1>
				<p className="admin-page__desc">{t("initiativesDesc")}</p>
			</div>
		</div>

		<div className="admin-card admin-card__body" style={{ marginBottom: 16 }}>
			<h2 className="admin-section-title">{editing ? t("initiativeEdit") : t("initiativeCreate")}</h2>
			<div className="admin-form">
				<div className="admin-field">
					<label htmlFor="init-name" className="admin-field__label">
						{t("initiativeName")}
					</label>
					<input
						id="init-name"
						aria-label={t("initiativeName")}
						className="l-input"
						value={form.name}
						placeholder={t("initiativeName")}
						onChange={(e) => setForm({ ...form, name: e.target.value })}
					/>
				</div>
				<div className="admin-field">
					<label htmlFor="init-slug" className="admin-field__label">
						{t("initiativeSlug")}
					</label>
					<input
						id="init-slug"
						aria-label={t("initiativeSlug")}
						className="l-input"
						value={form.slug}
						placeholder={t("initiativeSlug")}
						disabled={slugLocked}
						onChange={(e) => setForm({ ...form, slug: e.target.value })}
					/>
					{/* 锁定态仍原样回传 form.slug：后端 Ash.Changeset.do_change_attribute
					    在同值时把该键从 changeset.attributes 删除，而 changing_attribute?
					    只查 Map.has_key? ⇒ 不会误触发锁定守卫（#588）。 */}
					{slugLocked
						? <p className="admin-muted">{t("initiativeSlugLocked")}</p>
						: null}
				</div>
				<div className="admin-field">
					<label htmlFor="init-desc" className="admin-field__label">
						{t("initiativeDescription")}
					</label>
					<textarea
						id="init-desc"
						aria-label={t("initiativeDescription")}
						className="l-input"
						value={form.description}
						placeholder={t("initiativeDescription")}
						onChange={(e) => setForm({ ...form, description: e.target.value })}
					/>
				</div>
				<div>
					<button
						type="button"
						className="l-btn-primary"
						disabled={busy === "form"}
						onClick={() => void save()}
					>
						{t("initiativeSave")}
					</button>
					{editing
						? <button
							type="button"
							className="l-btn-outline"
							onClick={() => {
								setEditing(null);
								resetRuleEditing();
								setForm({ name: "", slug: "", description: "" });
							}}
						>
							{t("initiativeCancelEdit")}
						</button>
						: null}
				</div>
			</div>
		</div>

		{editing && rulesLoadedFor === editing
			? <div className="admin-card admin-card__body" style={{ marginBottom: 16 }}>
				<h2 className="admin-section-title">
					{mounts === null
						? t("initiativeMountsUnavailable")
						: t("initiativeMounts", { count: mounts.length })}
				</h2>
				{mounts === null
					? <p className="admin-alert admin-alert--error">{t("initiativeMountsLoadFailed")}</p>
					: mounts.length === 0
						? <p className="admin-muted">{t("initiativeMountsEmpty")}</p>
						: <div className="admin-table-wrap">
						<table className="admin-table">
							<thead>
								<tr>
									<th>{t("initiativeMountWorkspace")}</th>
									<th>{t("initiativeMountEvent")}</th>
									<th>{t("initiativeStatus")}</th>
									<th>{t("initiativeMountVenue")}</th>
									<th>{t("initiativeMountConfirmed")}</th>
									<th>{t("initiativeMountFunds")}</th>
									<th>{t("initiativeMountRuleSnapshot")}</th>
								</tr>
							</thead>
							<tbody>
								{mountList.map((mount) => <tr key={mount.id}>
									<td className="admin-table__primary">{mount.workspaceName}</td>
									<td>{mount.title}</td>
									<td>
										<span className={INITIATIVE_STATUS_CLASS[mount.status] ?? "l-badge l-badge-muted"}>
											{labelsT(`labels.eventStatus.${mount.status}`)}
										</span>
									</td>
									<td>{formatVenue(parseVenue(mount.venue)) ?? t("initiativeMountVenueTbd")}</td>
									<td>{mount.confirmedCount}</td>
									<td>
										<span className="admin-badge-row">
											<span className={mount.pricingEnabled ? "l-badge l-badge-success" : "l-badge l-badge-muted"}>
												{`${t("initiativeMountPricing")} ${mount.pricingEnabled ? t("initiativeMountOn") : t("initiativeMountOff")}`}
											</span>
											<span className={mount.depositEnabled ? "l-badge l-badge-success" : "l-badge l-badge-muted"}>
												{`${t("initiativeMountDeposit")} ${mount.depositEnabled ? t("initiativeMountOn") : t("initiativeMountOff")}`}
											</span>
										</span>
									</td>
									<td className="admin-muted">
										{[
											mount.minAge ? t("initiativeMountRuleAge", { age: mount.minAge }) : null,
											mount.minParticipants ? t("initiativeMountRuleMin", { count: mount.minParticipants }) : null,
											mount.registrationDeadline
												? t("initiativeMountRuleDeadline", { deadline: formatDateTime(mount.registrationDeadline) })
												: null,
										].filter(Boolean).join(" · ")}
									</td>
								</tr>)}
							</tbody>
						</table>
					</div>}

				<h2 className="admin-section-title" style={{ marginTop: 16 }}>{t("initiativeRules")}</h2>
				{RULE_KEYS.map((key) => {
					const rule = rules.find((item) => item.key === key);
					const locked = ruleLocks[key] ?? rule?.locked ?? false;
					return <div
						key={key}
						className="admin-field"
						/**
						 * 提交边界 = 本规则的字段容器（F1）。焦点在本容器内移动（鼠标点锁死开关、
						 * Tab 到本规则的 checkbox）不提交——那条路径由该控件的 onChange 负责；
						 * 焦点真正离开容器才提交草稿。鼠标 / Tab / Shift+Tab 三种离开方式语义一致，
						 * 不会出现"Tab 走人编辑静默不保存"。
						 *
						 * N6：弹层打开期间一律不提交。弹层打开会把焦点拉进弹层（F6），那会从本容器
						 * 里发出一次 focusout；此时若按渲染闭包里的旧 locked 提交，就会绕过确认、
						 * 把用户刚点下的「锁死」意图丢掉并发出一条未确认写入。弹层打开时鼠标被遮罩
						 * 挡住、键盘被焦点约束挡住，跳过提交不会丢任何用户动作。
						 */
						onBlur={(e) => {
							if (!rule) return;
							if (e.currentTarget.contains(e.relatedTarget)) return;
							const draft = ruleDrafts[key];
							if (draft === undefined) return;
							// 弹层打开期间由 requestRuleChange 的唯一入口守卫统一拦住（F1/N6）；
							// N7：用"锁死意图"而非渲染态 locked——在途写期间 ruleLocks 还是旧值
							requestRuleChange(key, draft, intendedLocked(key, locked));
						}}
					>
						<span className="admin-field__label">{t(`initiativeRule_${key}`)}</span>
						<textarea
							aria-label={t(`initiativeRule_${key}`)}
							className="l-input l-mono"
							value={draftValue(key, rule)}
							onChange={(e) => setRuleDrafts((current) => ({ ...current, [key]: e.target.value }))}
						/>
						<label>
							<input
								type="checkbox"
								checked={locked}
								disabled={(busyKeys[key] ?? 0) > 0}
								onChange={(e) => requestRuleChange(key, draftValue(key, rule), e.currentTarget.checked)}
							/> {t("initiativeRuleLocked")}
						</label>
					</div>;
				})}
			</div>
			: null}

		{pendingRule
			? <div
				role="dialog"
				aria-modal="true"
				aria-label={t("initiativeRuleImpactTitle")}
				className="admin-modal-overlay"
				onClick={() => cancelRuleChange(pendingRule.key)}
			>
				<div
					className="admin-modal"
					onClick={(e) => e.stopPropagation()}
				>
					<h2>{t("initiativeRuleImpactTitle")}</h2>
					<p>{t("initiativeRuleImpactRule", { rule: t(`initiativeRule_${pendingRule.key}`) })}</p>
					{mounts === null
						? <p>{t("initiativeRuleImpactUnavailable")}</p>
						: <>
							<p>{t("initiativeRuleImpactBody", {
								total: impact.total,
								draft: impact.draft,
								open: impact.open,
								terminal: impact.terminal,
							})}</p>
							<p>{t("initiativeRuleImpactConfirmed", { count: impact.confirmed })}</p>
							{/* 文案保留「可能/may」对冲（#641，勿当冗余措辞删掉）：① 提示对
							    「关闭押金」的变更也显示，而服务端守卫只在押金 enabling 时拒绝
							    （rule_inheritance.ex 的 deposit_enabling?/1）；② 清单是本地
							    快照，可能落后于真值。 */}
							{pendingRule.key === "deposit" && impact.pricingBlocked > 0
								? <p>{t("initiativeRuleImpactBlocked", { count: impact.pricingBlocked })}</p>
								: null}
							<p className="admin-muted">{t("initiativeRuleImpactServer")}</p>
						</>}
					<div className="admin-modal__actions">
						<button
							ref={cancelButtonRef}
							type="button"
							className="l-btn-outline"
							onClick={() => cancelRuleChange(pendingRule.key)}
						>
							{t("initiativeCancelEdit")}
						</button>
						<button
							ref={confirmButtonRef}
							type="button"
							className="l-btn-primary"
							disabled={(busyKeys[pendingRule.key] ?? 0) > 0}
							onClick={() => confirmRuleChange()}
						>
							{t("initiativeRuleImpactConfirm")}
						</button>
					</div>
				</div>
			</div>
			: null}

		{actionError ? <p className="admin-alert admin-alert--error" role="alert">{actionError}</p> : null}
		{error
			? <p className="admin-alert admin-alert--error" role="alert">{t("loadFailed")}</p>
			: rows === null
				? <p className="admin-muted">{t("loading")}</p>
				: rows.length === 0
					? <p className="admin-empty">{t("initiativesEmpty")}</p>
					: <div className="admin-card admin-table-wrap">
						<table className="admin-table">
							<thead>
								<tr>
									<th>{t("initiativeName")}</th>
									<th>{t("initiativeSlug")}</th>
									<th>{t("initiativeStatus")}</th>
									<th className="admin-table__actions">{t("initiativeAction")}</th>
								</tr>
							</thead>
							<tbody>
								{rows.map((row) =>
									<tr key={row.id}>
										<td className="admin-table__primary">{row.name}</td>
										<td>{row.slug}</td>
										<td>
											<span className={INITIATIVE_STATUS_CLASS[row.status] ?? "l-badge l-badge-muted"}>
												{labelsT(`labels.eventStatus.${row.status}`)}
											</span>
										</td>
										<td className="admin-table__actions">
											<button
												type="button"
												className="l-btn-outline"
												onClick={() => void copyLink(row)}
											>
												{copiedId === row.id ? t("initiativeLinkCopied") : t("initiativeCopyLink")}
											</button>
											<button
												type="button"
												className="l-btn-outline"
												// F4 判据 B：规则写入在途时不允许切换编辑对象——否则
												// "读早于写、落地晚于写"的交错会让旧快照盖掉新状态
												disabled={writesInFlight > 0}
												onClick={() => {
													if (writesInFlight > 0) return;
													setEditing(row.id);
													setForm({ name: row.name, slug: row.slug, description: row.description ?? "" });
													resetRuleEditing();
													loadInitiative(row.id);
												}}
											>
												{t("initiativeEdit")}
											</button>
											{row.status === "draft" || row.status === "open"
												? <button
													type="button"
													className="l-btn-outline"
													disabled={busy === row.id}
													onClick={() => void transition(row, row.status === "draft" ? "open" : "close")}
												>
													{row.status === "draft" ? t("initiativeOpen") : t("initiativeClose")}
												</button>
												: null}
											{row.status === "open"
												? <button
													type="button"
													className="l-btn-outline l-btn-outline--danger"
													disabled={busy === row.id}
													onClick={() => void transition(row, "cancel")}
												>
													{t("initiativeCancel")}
												</button>
												: null}
										</td>
									</tr>
								)}
							</tbody>
						</table>
					</div>}
	</section>;
}
