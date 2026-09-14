"use client";
import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { closeInitiative, createInitiative, fetchInitiative, fetchInitiatives, openInitiative, updateInitiative, upsertInitiativeRule } from "@/lib/admin";
import type { AdminInitiative, AdminInitiativeRule } from "@/lib/graphql/admin";
import type { MutationError } from "@/lib/graphql/shared";

const RULE_KEYS = ["deposit", "age_gate", "min_participants", "deadline_rule"] as const;

export default function AdminInitiativesPage() {
	const t = useTranslations("admin");
	const [rows, setRows] = useState<AdminInitiative[] | null>(null);
	const [error, setError] = useState(false);
	const [actionError, setActionError] = useState<string | null>(null);
	const [busy, setBusy] = useState<string | null>(null);
	const [form, setForm] = useState({ name: "", slug: "", description: "" });
	const [editing, setEditing] = useState<string | null>(null);
	const [rules, setRules] = useState<AdminInitiativeRule[]>([]);
	const [rulesLoadedFor, setRulesLoadedFor] = useState<string | null>(null);
	const [ruleBusy, setRuleBusy] = useState<string | null>(null);
	function firstError(payload: { errors: MutationError[] }): string {
		return payload.errors[0]?.message ?? t("loadFailed");
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

		<div className="admin-card" style={{ marginBottom: 16 }}>
			<h2>{editing ? t("initiativeEdit") : t("initiativeCreate")}</h2>
			<div style={{ display: "grid", gap: 8, maxWidth: 520 }}>
				<input
					aria-label={t("initiativeName")}
					value={form.name}
					placeholder={t("initiativeName")}
					onChange={(e) => setForm({ ...form, name: e.target.value })}
				/>
				<input
					aria-label={t("initiativeSlug")}
					value={form.slug}
					placeholder={t("initiativeSlug")}
					onChange={(e) => setForm({ ...form, slug: e.target.value })}
				/>
				<textarea
					aria-label={t("initiativeDescription")}
					value={form.description}
					placeholder={t("initiativeDescription")}
					onChange={(e) => setForm({ ...form, description: e.target.value })}
				/>
				<div>
					<button
						type="button"
						disabled={busy === "form"}
						onClick={() => void save()}
					>
						{t("initiativeSave")}
					</button>
					{editing
						? <button
							type="button"
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
			? <div className="admin-card" style={{ marginBottom: 16 }}>
				<h2>{t("initiativeRules")}</h2>
				{RULE_KEYS.map((key) => {
					const rule = rules.find((item) => item.key === key);
					const value = rule?.valueJson ?? "{}";
					return <div key={key} style={{ display: "grid", gap: 4, marginBottom: 12, maxWidth: 620 }}>
						<strong>{t(`initiativeRule_${key}`)}</strong>
						<textarea
							aria-label={t(`initiativeRule_${key}`)}
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

		{actionError ? <p role="alert">{actionError}</p> : null}
		{error
			? <p role="alert">{t("loadFailed")}</p>
			: rows === null
				? <p>{t("loading")}</p>
				: rows.length === 0
					? <p>{t("initiativesEmpty")}</p>
					: <div className="admin-card">
						<table>
							<thead>
								<tr>
									<th>{t("initiativeName")}</th>
									<th>{t("initiativeSlug")}</th>
									<th>{t("initiativeStatus")}</th>
									<th>{t("initiativeAction")}</th>
								</tr>
							</thead>
							<tbody>
								{rows.map((row) =>
									<tr key={row.id}>
										<td>{row.name}</td>
										<td>{row.slug}</td>
										<td>{row.status}</td>
										<td>
											<button
												type="button"
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
