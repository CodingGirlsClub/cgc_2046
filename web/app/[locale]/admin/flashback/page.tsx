"use client";

/**
 * /admin/flashback 闪念间看板（U11/R24/R25）。
 * 四率 + 分线（KTD10：分子 = touch distinct person，分母 = 成功送达——硬退信
 * 与退订剔除，记忆线/圆梦线分开）；导出 CSV 为聚合数字，结构性无 PII（KTD3）。
 * 兑换申请（R25）：人工处理队列——收款渠道由本人提交，状态流转
 * pending → contacted → settled | rejected（非法转移由后端 fail-closed 拒绝）。
 */
import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import {
	fetchFlashbackAdminRedemptions,
	fetchFlashbackAdminStats,
	updateFlashbackRedemption,
	fetchFlashbackAdminArchives,
	fetchFlashbackAdminWishInbox,
	fetchFlashbackAdminWishReports,
	approveFlashbackWishReport,
	dismissFlashbackWishReport,
	fetchFlashbackAdminListedWishes,
	fetchFlashbackOutreachPreview,
	fetchFlashbackOutreachBatches,
	fetchFlashbackOutreachRoster,
	sendFlashbackOutreach,
	resendFlashbackOutreach,
} from "@/lib/admin";
import { formatDateTime } from "@/lib/format";
import { WishEchoModal } from "@/components/admin/wish-echo-modal";
import type {
	FlashbackAdminStats,
	FlashbackRedemption,
	FlashbackAdminArchive,
	FlashbackOutreachPreview,
	FlashbackOutreachBatch,
	FlashbackOutreachRosterEntry,
	FlashbackAdminWishInboxEntry,
	FlashbackAdminReportEntry,
	FlashbackAdminListedWishEntry,
} from "@/lib/graphql/admin";

const EVENTS = [
	{ key: "linkOpened", label: "fbLinkOpened" },
	{ key: "revealed", label: "fbRevealed" },
	{ key: "sentToWall", label: "fbSentToWall" },
	{ key: "intentSubmitted", label: "fbIntentSubmitted" },
] as const;

/** 通道三档（R11）：select 选项与重发确认文案共用。 */
const CHANNELS = [
	{ value: "all", label: "fbChannelAll" },
	{ value: "email", label: "fbChannelEmail" },
	{ value: "sms", label: "fbChannelSms" },
] as const;

const LINES = [
	{ key: "memory", label: "fbLineMemory" },
	{ key: "dream", label: "fbLineDream" },
	{ key: "overall", label: "fbLineOverall" },
] as const;

/** 合法流转表（与后端 AdminStats.@status_transitions 同源；终态无操作）。 */
const NEXT_STATUSES: Record<string, string[]> = {
	pending: ["contacted", "settled", "rejected"],
	contacted: ["settled", "rejected"],
	settled: [],
	rejected: [],
};

const STATUS_LABEL: Record<string, string> = {
	pending: "fbStatusPending",
	contacted: "fbStatusContacted",
	settled: "fbStatusSettled",
	rejected: "fbStatusRejected",
};

const ACTION_LABEL: Record<string, string> = {
	contacted: "fbActionContacted",
	settled: "fbActionSettled",
	rejected: "fbActionRejected",
};

function pct(count: number, delivered: number): string {
	if (delivered <= 0) return "—";
	return `${Math.round((count / delivered) * 100)}%`;
}

export default function AdminFlashbackPage() {
	const t = useTranslations("admin");
	const [stats, setStats] = useState<FlashbackAdminStats | null>(null);
	const [rows, setRows] = useState<FlashbackRedemption[] | null>(null);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState(false);
	const [notes, setNotes] = useState<Record<string, string>>({});
	const [updateError, setUpdateError] = useState(false);

	// ── 触达运营台（R4/R7-R10） ──
	const [archives, setArchives] = useState<FlashbackAdminArchive[]>([]);
	const [outreachKey, setOutreachKey] = useState("");
	const [channel, setChannel] = useState("all");
	const [preview, setPreview] = useState<FlashbackOutreachPreview | null>(null);
	const [previewing, setPreviewing] = useState(false);
	const [sending, setSending] = useState(false);
	const [sendResult, setSendResult] = useState<{ queued: number; skipped: number } | null>(null);
	const [sendError, setSendError] = useState(false);
	const [batches, setBatches] = useState<FlashbackOutreachBatch[] | null>(null);
	const [roster, setRoster] = useState<FlashbackOutreachRosterEntry[] | null>(null);
	const [rosterFilter, setRosterFilter] = useState("");
	const [rosterSearch, setRosterSearch] = useState("");
	const [resendTarget, setResendTarget] = useState<FlashbackOutreachRosterEntry | null>(null);
	const [resendError, setResendError] = useState(false);
	const [archivesError, setArchivesError] = useState(false);
	const [previewError, setPreviewError] = useState(false);

	// ── wish2 愿望管理（U5/KTD5）：收件箱 + 举报队列 ──
	const [wishInbox, setWishInbox] = useState<FlashbackAdminWishInboxEntry[] | null>(null);
	const [wishReports, setWishReports] = useState<FlashbackAdminReportEntry[] | null>(null);
	const [listedWishes, setListedWishes] = useState<FlashbackAdminListedWishEntry[] | null>(null);
	const [echoTarget, setEchoTarget] = useState<FlashbackAdminListedWishEntry | null>(null);
	const [wishError, setWishError] = useState(false);

	const loadWishes = useCallback(() => {
		return Promise.all([
			fetchFlashbackAdminWishInbox(),
			fetchFlashbackAdminWishReports(),
			fetchFlashbackAdminListedWishes(),
		])
			.then(([inbox, reports, listed]) => {
				setWishInbox(inbox);
				setWishReports(reports);
				setListedWishes(listed);
				setWishError(false);
			})
			.catch(() => {
				setWishError(true);
				setWishInbox(null);
				setWishReports(null);
				setListedWishes(null);
			});
	}, []);

	// .then/.catch 链（reconciliation 页模式）：effect 内调用不触发 set-state-in-effect
	const loadOutreachBase = useCallback(() => {
		return fetchFlashbackAdminArchives()
			.then((rows) => {
				setArchives(rows);
				setArchivesError(false);
			})
			.catch(() => setArchivesError(true));
	}, []);

	const load = useCallback(() => {
		void loadOutreachBase();
		void loadWishes();
		return Promise.all([
			fetchFlashbackAdminStats(),
			fetchFlashbackAdminRedemptions(),
		])
			.then(([s, r]) => {
				setStats(s);
				setRows(r);
				setError(false);
			})
			.catch(() => {
				setError(true);
				setStats(null);
				setRows([]);
			})
			.finally(() => {
				setLoading(false);
			});
	}, [loadOutreachBase]);

	useEffect(() => {
		void load();
	}, [load]);

	/** 导出 = 聚合矩阵（线 × 送达 + 四事件计数与率），无任何个人级字段（KTD3）。 */
	const exportCsv = () => {
		if (!stats) return;
		const header = [
			t("fbLine"),
			t("fbDelivered"),
			...EVENTS.flatMap((e) => [t(e.label), `${t(e.label)}${t("fbRateSuffix")}`]),
		];
		const body = LINES.map(({ key, label }) => {
			const r = stats[key];
			return [
				t(label),
				String(r.delivered),
				...EVENTS.flatMap((e) => [
					String(r[e.key]),
					pct(r[e.key], r.delivered),
				]),
			];
		});
		const csv = [header, ...body]
			.map((cells) => cells.map((c) => `"${c.replaceAll('"', '""')}"`).join(","))
			.join("\r\n");
		const blob = new Blob([`\uFEFF${csv}`], { type: "text/csv;charset=utf-8" });
		const url = URL.createObjectURL(blob);
		const a = document.createElement("a");
		a.href = url;
		a.download = "flashback-stats.csv";
		a.click();
		URL.revokeObjectURL(url);
	};

	const handleTransition = (id: string, status: string) => {
		updateFlashbackRedemption(id, status, notes[id]?.trim() || undefined)
			.then(() => {
				setUpdateError(false);
				return load();
			})
			.catch(() => setUpdateError(true));
	};

	const loadBatchesAndRoster = useCallback((key: string) => {
		if (!key) return Promise.resolve();
		return Promise.all([
			fetchFlashbackOutreachBatches(key),
			fetchFlashbackOutreachRoster(key, rosterFilter || undefined, rosterSearch || undefined),
		])
			.then(([b, r]) => {
				setBatches(b);
				setRoster(r);
			})
			.catch(() => {
				setBatches([]);
				setRoster([]);
			});
	}, [rosterFilter, rosterSearch]);

	const handlePreview = () => {
		if (!outreachKey) return;
		setPreviewing(true);
		setSendResult(null);
		fetchFlashbackOutreachPreview(outreachKey, channel)
			.then((p) => {
				setPreview(p);
				setPreviewError(false);
			})
			.catch(() => setPreviewError(true))
			.finally(() => setPreviewing(false));
	};

	const handleSend = () => {
		if (!preview || preview.queued === 0) return;
		setSending(true);
		sendFlashbackOutreach(outreachKey, "reconnect", channel)
			.then((r) => {
				if (r) setSendResult(r);
				setSendError(false);
				return loadBatchesAndRoster(outreachKey);
			})
			.catch(() => setSendError(true))
			.finally(() => setSending(false));
	};

	const handleRosterReload = (key: string, filter: string, search?: string) => {
		fetchFlashbackOutreachRoster(key, filter || undefined, search || undefined)
			.then(setRoster)
			.catch(() => setRoster([]));
	};

	const handleResend = (entry: FlashbackOutreachRosterEntry) => {
		setResendError(false);
		resendFlashbackOutreach(entry.personId, "reconnect", channel)
			.then(() => {
				setResendTarget(null);
				return loadBatchesAndRoster(outreachKey);
			})
			.catch(() => setResendError(true));
	};

	return (
		<section>
			<div className="admin-page__head">
				<div>
					<h1>{t("flashbackTitle")}</h1>
					<p className="admin-page__desc">{t("flashbackDesc")}</p>
				</div>
				{stats && (
					<button type="button" onClick={exportCsv} className="l-btn-outline">
						{t("fbExport")}
					</button>
				)}
			</div>

			{error && <p className="admin-alert admin-alert--error">{t("loadFailed")}</p>}
			{loading && <p className="admin-muted">{t("loading")}</p>}

			{!loading && !error && stats && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("fbLine")}</th>
								<th>{t("fbDelivered")}</th>
								{EVENTS.map((e) => (
									<th key={e.key}>{t(e.label)}</th>
								))}
							</tr>
						</thead>
						<tbody>
							{LINES.map(({ key, label }) => {
								const r = stats[key];
								return (
									<tr key={key}>
										<td>{t(label)}</td>
										<td>{r.delivered}</td>
										{EVENTS.map((e) => (
											<td key={e.key}>
												{r[e.key]} ({pct(r[e.key], r.delivered)})
											</td>
										))}
									</tr>
								);
							})}
						</tbody>
					</table>
				</div>
			)}

			{/* ── 触达发送（R7/R4/KTD1/KTD2） ── */}
			{!loading && !error && (
				<div className="admin-page__head">
					<div>
						<h2>{t("fbOutreachTitle")}</h2>
						<p className="admin-page__desc">{t("fbOutreachNote")}</p>
					</div>
				</div>
			)}

			{!loading && !error && archivesError && (
				<p className="admin-alert admin-alert--error">{t("fbLoadArchivesFailed")}</p>
			)}

			{!loading && !error && !archivesError && (
				<div className="admin-card admin-toolbar">
					<select
						value={outreachKey}
						onChange={(e) => {
							setOutreachKey(e.target.value);
							setPreview(null);
							setSendResult(null);
							setBatches(null);
							setRoster(null);
							void loadBatchesAndRoster(e.target.value);
						}}
						aria-label={t("fbSelectArchive")}
						className="l-input"
					>
						<option value="">{t("fbSelectArchive")}</option>
						{archives.map((a) => (
							<option key={a.key} value={a.key}>
								{a.name} · {a.key}
							</option>
						))}
					</select>
					<select
						value={channel}
						onChange={(e) => {
							setChannel(e.target.value);
							setPreview(null);
							setSendResult(null);
						}}
						aria-label={t("fbSelectChannel")}
						className="l-input"
					>
						{CHANNELS.map((c) => (
							<option key={c.value} value={c.value}>
								{t(c.label)}
							</option>
						))}
					</select>
					<button
						type="button"
						onClick={handlePreview}
						disabled={!outreachKey || previewing}
						className="l-btn-outline"
					>
						{t("fbPreview")}
					</button>
				</div>
			)}

			{!loading && !error && previewError && (
				<p className="admin-alert admin-alert--error">{t("loadFailed")}</p>
			)}

			{!loading && !error && preview && (
				<div className="admin-card">
					<p>
						{t("fbQueued")}: <strong>{preview.queued}</strong> ·{" "}
						{t("fbEmailOnly")}: {preview.emailOnly} · {t("fbSmsOnly")}: {preview.smsOnly} ·{" "}
						{t("fbBoth")}: {preview.both} · {t("fbUnsubscribedExcluded")}:{" "}
						{preview.unsubscribed} · {t("fbUnreachable")}: {preview.unreachable}
					</p>
					{!preview.smsReady && (
						<p className="admin-alert admin-alert--error">{t("fbSmsNotReady")}</p>
					)}
					{preview.queued === 0 && <p className="admin-empty">{t("fbNoReachable")}</p>}
					<button
						type="button"
						onClick={handleSend}
						disabled={sending || preview.queued === 0}
						className="l-btn-outline"
					>
						{t("fbConfirmSend")}
					</button>
				</div>
			)}

			{!loading && !error && sendResult && (
				<p className="admin-alert admin-alert--info">
					{t("fbSendDone", {
						queued: sendResult.queued,
						skipped: sendResult.skipped,
					})}
				</p>
			)}
			{!loading && !error && sendError && (
				<p className="admin-alert admin-alert--error">{t("loadFailed")}</p>
			)}

			{/* ── 批次历史（R8） ── */}
			{!loading && !error && (
				<div className="admin-page__head">
					<div>
						<h2>{t("fbBatchesTitle")}</h2>
						<p className="admin-page__desc">{t("fbBatchesNote")}</p>
					</div>
				</div>
			)}

			{!loading && !error && batches && batches.length === 0 && (
				<p className="admin-empty">{t("fbNoBatches")}</p>
			)}

			{!loading && !error && batches && batches.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("fbThBatch")}</th>
								<th>{t("fbThTemplate")}</th>
								<th>{t("fbEmailShort")}</th>
								<th>{t("fbSmsShort")}</th>
								<th>{t("fbThFirstAt")}</th>
							</tr>
						</thead>
						<tbody>
							{batches.map((b) => (
								<tr key={b.batch}>
									<td>{b.batch}</td>
									<td>{b.template}</td>
									<td>
										{t("fbStatusQueued")} {b.email.queued} · {t("fbStatusSent")}{" "}
										{b.email.sent} · {t("fbThFailed")} {b.email.failed}
									</td>
									<td>
										{t("fbStatusQueued")} {b.sms.queued} · {t("fbStatusSent")} {b.sms.sent} ·{" "}
										{t("fbThFailed")} {b.sms.failed}
									</td>
									<td>{b.firstAt ? formatDateTime(b.firstAt) : "—"}</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			)}

			{/* ── 名册（R9/R10） ── */}
			{!loading && !error && (
				<div className="admin-page__head">
					<div>
						<h2>{t("fbRosterTitle")}</h2>
						<p className="admin-page__desc">{t("fbRosterNote")}</p>
					</div>
				</div>
			)}

			{!loading && !error && (
				<div className="admin-card admin-toolbar">
					<select
						value={rosterFilter}
						onChange={(e) => {
							setRosterFilter(e.target.value);
							handleRosterReload(outreachKey, e.target.value, rosterSearch);
						}}
						aria-label={t("fbRosterTitle")}
						className="l-input"
					>
						<option value="">{t("fbFilterAll")}</option>
						<option value="unclaimed">{t("fbFilterUnclaimed")}</option>
						<option value="unsubscribed">{t("fbFilterUnsubscribed")}</option>
						<option value="sms_only">{t("fbFilterSmsOnly")}</option>
						<option value="send_failed">{t("fbFilterSendFailed")}</option>
					</select>
					<input
						value={rosterSearch}
						onChange={(e) => setRosterSearch(e.target.value)}
						onKeyDown={(e) => {
							if (e.key === "Enter") handleRosterReload(outreachKey, rosterFilter, rosterSearch);
						}}
						placeholder={t("fbSearchPlaceholder")}
						aria-label={t("fbSearchPlaceholder")}
						className="l-input"
					/>
					<button
						type="button"
						onClick={() => handleRosterReload(outreachKey, rosterFilter, rosterSearch)}
						className="l-btn-outline"
					>
						{t("fbSearchPlaceholder")}
					</button>
				</div>
			)}

			{!loading && !error && resendError && (
				<p className="admin-alert admin-alert--error">{t("fbResendFailed")}</p>
			)}

			{!loading && !error && roster && roster.length === 0 && (
				<p className="admin-empty">{t("fbNoRoster")}</p>
			)}

			{!loading && !error && roster && roster.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("fbThFullName")}</th>
								<th>{t("fbThEmailAddr")}</th>
								<th>{t("fbThPhone")}</th>
								<th>{t("fbThClaimed")}</th>
								<th>{t("fbThParticipation")}</th>
								<th>{t("fbThUnsub")}</th>
								<th>{t("fbThDeleted")}</th>
								<th>{t("fbThReach")}</th>
								<th>{t("fbThLast")}</th>
								<th>{t("fbThActions")}</th>
							</tr>
						</thead>
						<tbody>
							{roster.map((entry) => (
								<tr key={entry.personId}>
									<td>{entry.fullName}</td>
									<td>{entry.email ?? "—"}</td>
									<td>{entry.phone ?? "—"}</td>
									<td>{entry.claimed ? t("fbYes") : t("fbNo")}</td>
									<td>
										{entry.participation === "attended"
											? t("fbPartAttended")
											: t("fbPartNotSelected")}
									</td>
									<td>{entry.unsubscribed ? t("fbYes") : t("fbNo")}</td>
									<td>{entry.deleted ? t("fbYes") : t("fbNo")}</td>
									<td>
										{[entry.emailReachable ? t("fbChannelEmail") : null, entry.smsReachable ? t("fbSmsShort") : null]
											.filter(Boolean)
											.join("/") || "—"}
									</td>
									<td>
										{entry.lastOutreach
											? `${t(entry.lastOutreach.channel === "email" ? "fbEmailShort" : "fbSmsShort")} · ${t(entry.lastOutreach.status === "sent" ? "fbStatusSent" : entry.lastOutreach.status === "failed" ? "fbThFailed" : "fbStatusQueued")}`
											: "—"}
									</td>
									<td>
										{resendTarget?.personId === entry.personId ? (
											<div className="admin-toolbar">
												<span>
													{t("fbResendConfirm", {
														name: entry.fullName,
														channel: t(
															CHANNELS.find((c) => c.value === channel)
																?.label ?? "fbChannelAll",
														),
													})}
												</span>
												<button
													type="button"
													onClick={() => handleResend(entry)}
													className="l-btn-outline"
												>
													{t("fbResendOk")}
												</button>
												<button
													type="button"
													onClick={() => setResendTarget(null)}
													className="l-btn-outline"
												>
													{t("fbResendCancel")}
												</button>
											</div>
										) : (
											<button
												type="button"
												onClick={() => {
													setResendError(false);
													setResendTarget(entry);
												}}
												disabled={entry.claimed || entry.unsubscribed || entry.deleted}
												className="l-btn-outline"
											>
												{t("fbResend")}
											</button>
										)}
									</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			)}

			{!loading && !error && rows && (
				<div className="admin-page__head">
					<div>
						<h2>{t("fbRedeemTitle")}</h2>
						<p className="admin-page__desc">{t("fbRedeemNote")}</p>
					</div>
				</div>
			)}

			{updateError && (
				<p className="admin-alert admin-alert--error">{t("fbUpdateFailed")}</p>
			)}

			{!loading && !error && rows && rows.length === 0 && (
				<p className="admin-empty">{t("fbNoRedemptions")}</p>
			)}

			{!loading && !error && rows && rows.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("fbThMaskedName")}</th>
								<th>{t("fbThCity")}</th>
								<th>{t("fbThChannel")}</th>
								<th>{t("fbThStatus")}</th>
								<th>{t("fbThNote")}</th>
								<th>{t("fbThTime")}</th>
								<th>{t("fbThActions")}</th>
							</tr>
						</thead>
						<tbody>
							{rows.map((row) => (
								<tr key={row.id}>
									<td>{row.maskedName ?? "—"}</td>
									<td>{row.city ?? "—"}</td>
									<td>{row.channelNote}</td>
									<td>{t(STATUS_LABEL[row.status] ?? row.status)}</td>
									<td>{row.handledNote ?? "—"}</td>
									<td>{row.insertedAt ? formatDateTime(row.insertedAt) : "—"}</td>
									<td>
										{(NEXT_STATUSES[row.status] ?? []).length > 0 && (
											<div className="admin-toolbar">
												<input
													value={notes[row.id] ?? ""}
													onChange={(e) =>
														setNotes((prev) => ({
															...prev,
															[row.id]: e.target.value,
														}))
													}
													placeholder={t("fbNotePlaceholder")}
													aria-label={`${t("fbThNote")} ${row.maskedName ?? row.id}`}
													className="l-input"
												/>
												{(NEXT_STATUSES[row.status] ?? []).map((next) => (
													<button
														key={next}
														type="button"
														onClick={() => handleTransition(row.id, next)}
														className="l-btn-outline"
													>
														{t(ACTION_LABEL[next])}
													</button>
												))}
											</div>
										)}
										{(NEXT_STATUSES[row.status] ?? []).length === 0 && "—"}
									</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			)}

			{!loading && !error && (
				<div className="admin-page__head">
					<div>
						<h2>{t("fbWishTitle")}</h2>
						<p className="admin-page__desc">{t("fbWishNote")}</p>
					</div>
				</div>
			)}

			{wishError && <p className="admin-alert admin-alert--error">{t("fbWishLoadFailed")}</p>}

			{!loading && !error && wishInbox && (
				<div className="admin-card admin-table-wrap" data-testid="fb-wish-inbox">
					<h3>{t("fbWishInboxTitle")}</h3>
					{wishInbox.length === 0 ? (
						<p className="admin-empty">{t("fbWishInboxEmpty")}</p>
					) : (
						<table className="admin-table">
							<thead>
								<tr>
									<th>{t("fbWishColContent")}</th>
									<th>{t("fbWishColSigner")}</th>
									<th>{t("fbWishColContact")}</th>
									<th>{t("fbWishColTime")}</th>
								</tr>
							</thead>
							<tbody>
								{wishInbox.map((entry) => (
									<tr key={entry.wishId}>
										<td>{entry.content}</td>
										<td>
											{entry.wisherMasked ?? entry.signature}
										</td>
										<td>
											{entry.wisherPhone ?? "—"} / {entry.wisherEmail ?? "—"}
										</td>
										<td>{formatDateTime(entry.insertedAt)}</td>
									</tr>
								))}
							</tbody>
						</table>
					)}
				</div>
			)}

			{!loading && !error && listedWishes && (
				<div className="admin-card admin-table-wrap" data-testid="fb-wish-listed">
					<h3>{t("fbWishListedTitle")}</h3>
					{listedWishes.length === 0 ? (
						<p className="admin-empty">{t("fbWishListedEmpty")}</p>
					) : (
						<table className="admin-table">
							<thead>
								<tr>
									<th>{t("fbWishColContent")}</th>
									<th>{t("fbWishColSigner")}</th>
									<th>{t("fbWishColCity")}</th>
									<th>{t("fbWishColListedAt")}</th>
									<th>{t("fbWishColEchoes")}</th>
									<th>{t("fbWishColActions")}</th>
								</tr>
							</thead>
							<tbody>
								{listedWishes.map((entry) => (
									<tr key={entry.wishId}>
										<td>{entry.content}</td>
										<td>{entry.signature ?? "—"}</td>
										<td>{entry.city ?? "—"}</td>
										<td>{formatDateTime(entry.listedAt)}</td>
										<td data-testid="fb-echo-count">
											{t("fbWishEchoCount", {
												published: entry.publishedEchoCount,
												draft: entry.draftEchoCount,
											})}
										</td>
										<td>
											<div className="admin-table__actions">
												<button
													type="button"
													className="l-btn-outline"
													data-testid={`fb-echo-open-${entry.wishId}`}
													onClick={() => setEchoTarget(entry)}
												>
													{t("fbEchoOpen")}
												</button>
											</div>
										</td>
									</tr>
								))}
							</tbody>
						</table>
					)}
				</div>
			)}

			{!loading && !error && wishReports && (
				<div className="admin-card admin-table-wrap" data-testid="fb-wish-reports">
					<h3>{t("fbWishReportsTitle")}</h3>
					{wishReports.length === 0 ? (
						<p className="admin-empty">{t("fbWishReportsEmpty")}</p>
					) : (
						<table className="admin-table">
							<thead>
								<tr>
									<th>{t("fbWishColReason")}</th>
									<th>{t("fbWishColDetail")}</th>
									<th>{t("fbWishColTime")}</th>
									<th>{t("fbWishColActions")}</th>
								</tr>
							</thead>
							<tbody>
								{wishReports.map((report) => (
									<tr key={report.reportId}>
										<td>{t(`fbWishReason_${report.reasonType}`)}</td>
										<td>{report.reasonFree ?? "—"}</td>
										<td>{formatDateTime(report.insertedAt)}</td>
										<td>
											<div className="admin-table__actions">
												<button
													type="button"
													className="l-btn-outline"
													onClick={() => {
														approveFlashbackWishReport(report.reportId)
															.then(() => loadWishes())
															.catch(() => setWishError(true));
													}}
												>
													{t("fbWishReportApprove")}
												</button>
												<button
													type="button"
													className="l-btn-outline"
													onClick={() => {
														dismissFlashbackWishReport(report.reportId)
															.then(() => loadWishes())
															.catch(() => setWishError(true));
													}}
												>
													{t("fbWishReportDismiss")}
												</button>
											</div>
										</td>
									</tr>
								))}
							</tbody>
						</table>
					)}
				</div>
			)}
			{echoTarget && (
				<WishEchoModal
					wishId={echoTarget.wishId}
					wishPreview={echoTarget.content}
					onClose={() => setEchoTarget(null)}
					onChanged={() => void loadWishes()}
				/>
			)}
		</section>
	);
}
