"use client";

/**
 * 定价配置管理面板（plan 024 follow-up U2-R1：收费 Event/Course 的
 * pricingEnabled 开关 + PriceTier 档位编辑）。
 *
 * - 目标选择：工作台 offerings 列表（fetchWorkspaceOfferings）→ 逐目标编辑；
 *   列表带 pricingEnabled/priceTiers 快照（写后本地刷新）。
 * - 档位编辑：id/name/amountCents/availableUntil 结构化行编辑（SponsorshipManagement
 *   的 draft 模式）；校验同步后端 PriceTiersValidation 语义：金额 ≥ 1 分（无
 *   0 元档）、启用时至少一档、缺 name 拒绝——前端先拦，后端兜底。
 * - 保存：updateOffering(id, kind, { pricingEnabled, priceTiers })（JsonString
 *   数组序列化在此层完成）。
 * - 门控：manage（Owner/Admin，宿主传入）——非管理只读展示。
 *
 * 组件测试面：开关切换/增删档/校验提示/保存 mutation 变量（见 test）。
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import {
	LIST_COURSES,
	LIST_EVENTS,
	type OfferingItem,
	type OfferingKind,
} from "@/lib/graphql/events";
import { updateOffering } from "@/lib/events";
import { formatAmount } from "@/lib/payment";
import TierEditor, { fromDraft, toDraft, type TierDraft } from "@/components/tier-editor";

export default function PricingManagement({
	workspaceId,
	manage,
}: {
	workspaceId: string;
	manage: boolean;
}) {
	const t = useTranslations("pricing");
	const [offerings, setOfferings] = useState<Array<OfferingItem & { kind: OfferingKind }>>([]);
	const [selectedId, setSelectedId] = useState<string | null>(null);
	const [drafts, setDrafts] = useState<TierDraft[]>([]);
	const [pricingEnabled, setPricingEnabled] = useState(false);
	const [loadState, setLoadState] = useState<"loading" | "ok" | "error">("loading");
	const [dirty, setDirty] = useState(false);
	const [saving, setSaving] = useState(false);
	const [saveError, setSaveError] = useState<string | null>(null);
	const [savedFlash, setSavedFlash] = useState(false);
	const loadedFor = useRef("");

	const load = useCallback(
		async (selectId: string | null) => {
			setLoadState("loading");
			try {
				const [eventsRes, coursesRes] = await Promise.all([
					client.query({ query: LIST_EVENTS, variables: { workspaceId } }),
					client.query({ query: LIST_COURSES, variables: { workspaceId } }),
				]);
				const rows: Array<OfferingItem & { kind: OfferingKind }> = [
					...(eventsRes.data?.listEvents?.results ?? []).map((r) => ({ ...r, kind: "event" as const })),
					...(coursesRes.data?.listCourses?.results ?? []).map((r) => ({ ...r, kind: "course" as const })),
				];
				setOfferings(rows);
				const target = selectId ? rows.find((r) => r.id === selectId) : rows[0];
				if (target) {
					setSelectedId(target.id);
					setPricingEnabled(target.pricingEnabled === true);
					setDrafts(toDraft(target.priceTiers));
				} else {
					setSelectedId(null);
				}
				setDirty(false);
				setLoadState("ok");
			} catch {
				setLoadState("error");
			}
		},
		[workspaceId],
	);

	useEffect(() => {
		if (!workspaceId || loadedFor.current === workspaceId) return;
		loadedFor.current = workspaceId;
		void load(null);
	}, [workspaceId, load]);

	const selected = offerings.find((o) => o.id === selectedId) ?? null;

	function selectOffering(id: string) {
		const target = offerings.find((o) => o.id === id);
		if (!target) return;
		setSelectedId(id);
		setPricingEnabled(target.pricingEnabled === true);
		setDrafts(toDraft(target.priceTiers));
		setDirty(false);
		setSaveError(null);
	}

	/** 有效档位数（行级校验通过） */
	const validTiers = drafts.map(fromDraft).filter((t) => t !== null);
	const invalidCount = drafts.length - validTiers.length;
	const enableBlocked = pricingEnabled && validTiers.length === 0;

	function patchDrafts(next: TierDraft[]) {
		setDrafts(next);
		setDirty(true);
	}

	async function save() {
		if (!selected || saving) return;
		if (invalidCount > 0 || enableBlocked) {
			setSaveError(t("validation"));
			return;
		}
		setSaving(true);
		setSaveError(null);
		try {
			const res = await updateOffering(selected.id, selected.kind, {
				pricingEnabled,
				priceTiers: validTiers.map((t) => JSON.stringify(t)),
			});
			if (res.result) {
				setDirty(false);
				setSavedFlash(true);
				setTimeout(() => setSavedFlash(false), 2000);
				await load(selected.id);
			} else {
				setSaveError(res.errors[0]?.message ?? t("saveFailedRetry"));
			}
		} catch (e) {
			setSaveError(e instanceof Error ? e.message : t("saveFailedRetry"));
		} finally {
			setSaving(false);
		}
	}

	if (loadState === "loading") {
		return <div className="h-40 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />;
	}

	if (loadState === "error") {
		return (
			<div className="rounded-large border border-line bg-card p-6 text-sm text-ink-3">
				{t("loadFailed")}
				<button type="button" className="underline" onClick={() => void load(null)}>
					{t("retry")}
				</button>
			</div>
		);
	}

	if (offerings.length === 0) {
		return (
			<div className="rounded-large border border-line bg-card p-6 text-sm text-ink-3">
				{t("noOfferings")}
			</div>
		);
	}

	return (
		<div className="grid gap-4" data-testid="pricing-management">
			{/* 目标选择 */}
			<div className="rounded-large border border-line bg-card p-4">
				<h2 className="text-sm font-medium text-ink">{t("chooseTarget")}</h2>
				<div className="mt-3 flex flex-wrap gap-2">
					{offerings.map((o) => (
						<button
							key={o.id}
							type="button"
							className={`rounded-large border px-3 py-1.5 text-sm ${
								selectedId === o.id
									? "border-line-strong bg-soft-2 text-ink"
									: "border-line bg-card text-ink-2"
							}`}
							data-testid={`pricing-target-${o.id}`}
							onClick={() => selectOffering(o.id)}
						>
							{o.title}
							{o.pricingEnabled ? t("paidSuffix") : ""}
						</button>
					))}
				</div>
			</div>

			{selected && (
				<div className="rounded-large border border-line bg-card p-4" data-testid="pricing-editor">
					<div className="flex flex-wrap items-center justify-between gap-3">
						<h2 className="text-sm font-medium text-ink">
							{t("configTitle", { title: selected.title })}
						</h2>
						<label
							className={`flex items-center gap-2 text-sm text-ink-2 ${manage ? "cursor-pointer" : ""}`}
						>
							<input
								type="checkbox"
								checked={pricingEnabled}
								disabled={!manage}
								onChange={(e) => {
									setPricingEnabled(e.target.checked);
									setDirty(true);
								}}
								data-testid="pricing-toggle"
							/>
							{t("enablePaid")}
						</label>
					</div>

					<p className="mt-2 text-[13px] text-ink-3">
						{t("enablePaidHint")}
					</p>

					{/* 档位编辑（免费态也可预配，保存时后端校验配对）；U6 起复用共享 TierEditor */}
					<div className="mt-4">
						<TierEditor drafts={drafts} onChange={patchDrafts} manage={manage} />
					</div>

					{/* 校验提示（同步后端 PriceTiersValidation 语义） */}
					{invalidCount > 0 && (
						<p role="alert" className="mt-2 text-[13px] text-red-300" data-testid="tier-invalid">
							{t("validation")}
						</p>
					)}
					{enableBlocked && invalidCount === 0 && (
						<p role="alert" className="mt-2 text-[13px] text-red-300" data-testid="tier-blocked">
							{t("tierBlocked")}
						</p>
					)}

					{saveError && (
						<p role="alert" className="mt-2 text-[13px] text-red-300" data-testid="pricing-error">
							{saveError}
						</p>
					)}

					{manage && (
						<div className="mt-4 flex flex-wrap items-center gap-3">
							<button
								type="button"
								className="rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
								onClick={() => void save()}
								disabled={saving || !dirty}
								data-testid="pricing-save"
							>
								{saving ? t("saving") : t("saveConfig")}
							</button>
							{savedFlash && (
								<span role="status" className="text-sm text-emerald-300" data-testid="pricing-saved">
									{t("saved")}
								</span>
							)}
						</div>
					)}

					{/* 只读预览（保存后快照回显） */}
					{!dirty && validTiers.length > 0 && (
						<p className="mt-3 text-[13px] text-ink-3" data-testid="tier-preview">
							{t("currentTiers")}
							{validTiers
								.map(
									(t) =>
										`${t.name as string} ¥${formatAmount(t.amount_cents as number)}`,
								)
								.join(" / ")}
						</p>
					)}
				</div>
			)}
		</div>
	);
}
