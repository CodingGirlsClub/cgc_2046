"use client";
import { useEffect, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { closeInitiative, createInitiative, fetchInitiative, fetchInitiatives, openInitiative, updateInitiative, upsertInitiativeRule } from "@/lib/admin";
import { copyText } from "@/lib/clipboard";
import { localizedUrl } from "@/lib/seo";
import {
	INITIATIVE_STATUS_CLASS,
	type AdminInitiative,
	type AdminInitiativeRule,
} from "@/lib/graphql/admin";
import type { MutationError } from "@/lib/graphql/shared";

const RULE_KEYS = ["deposit", "age_gate", "min_participants", "deadline_rule"] as const;

export default function AdminInitiativesPage() {
	const t = useTranslations("admin");
	const labelsT = useTranslations();
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
	const [ruleBusy, setRuleBusy] = useState<string | null>(null);
	function firstError(payload: { errors: MutationError[] }): string {
		return payload.errors[0]?.message ?? t("loadFailed");
	}
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
	async function transition(row: AdminInitiative) {
		setBusy(row.id);
		setActionError(null);
		const result = row.status === "draft" ? await openInitiative(row.id) : row.status === "open" ? await closeInitiative(row.id) : null;
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
			setRules([]);
			setRulesLoadedFor(null);
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
						onChange={(e) => setForm({ ...form, slug: e.target.value })}
					/>
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
								setRules([]);
								setRulesLoadedFor(null);
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
				<h2 className="admin-section-title">{t("initiativeRules")}</h2>
				{RULE_KEYS.map((key) => {
					const rule = rules.find((item) => item.key === key);
					const value = rule?.valueJson ?? "{}";
					return <div key={key} className="admin-field">
						<span className="admin-field__label">{t(`initiativeRule_${key}`)}</span>
						<textarea
							aria-label={t(`initiativeRule_${key}`)}
							className="l-input l-mono"
							defaultValue={value}
							onBlur={(e) => {
								if (!rule) return;
								setRuleBusy(key);
								void upsertInitiativeRule(editing, key, e.currentTarget.value, rule.locked).then((result) => {
									if (result.result) setRules((current) => current.map((item) => item.key === key ? { ...item, ...result.result } : item));
									else setActionError(firstError(result));
								}).finally(() => setRuleBusy(null));
							}}
						/>
						<label>
							<input
								type="checkbox"
								defaultChecked={rule?.locked ?? false}
								disabled={ruleBusy === key}
								onChange={(e) => {
									const next = e.currentTarget.checked;
									const currentValue = e.currentTarget.closest("div")?.querySelector("textarea")?.value ?? value;
									setRuleBusy(key);
									void upsertInitiativeRule(editing, key, currentValue, next).then((result) => {
										if (result.result) setRules((current) => current.map((item) => item.key === key ? { ...item, ...result.result } : item));
										else setActionError(firstError(result));
									}).finally(() => setRuleBusy(null));
								}}
							/> {t("initiativeRuleLocked")}
						</label>
					</div>;
				})}
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
												onClick={() => {
													setEditing(row.id);
													setForm({ name: row.name, slug: row.slug, description: row.description ?? "" });
													setRules([]);
													setRulesLoadedFor(null);
													void fetchInitiative(row.id).then((details) => {
														setRules(details?.rules ?? []);
														setRulesLoadedFor(row.id);
													});
												}}
											>
												{t("initiativeEdit")}
											</button>
											{row.status !== "closed"
												? <button
													type="button"
													className="l-btn-outline"
													disabled={busy === row.id}
													onClick={() => void transition(row)}
												>
													{row.status === "draft" ? t("initiativeOpen") : t("initiativeClose")}
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
