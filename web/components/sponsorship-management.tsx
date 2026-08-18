"use client";

/**
 * E-3 #48 Owner 管理面：赞助档位配置 + 赞助列表（状态/档位/账本进度）+
 * 履约账本核销（勾销 + proof_note）。
 *
 * - 档位配置：结构化编辑（名称/建议金额/权益项列表/独占位标记），保存经宿主
 *   注入的 onSaveTiers 回调（Event 级走 updateEvent、Workspace 级走
 *   updateWorkspace——JsonString 数组序列化由宿主负责）。
 * - 赞助列表：LIST_EVENT_SPONSORSHIPS / LIST_WORKSPACE_SPONSORSHIPS（按目标）。
 * - 账本核销：fulfillDelivery（fulfilled_at + proof_note），重复核销后端拒绝；
 *   欠交付 = fulfilledAt 为空的未核销行自然可见（D5，不做 makegood）。
 */

import { useMemo, useState } from "react";
import { useTranslations } from "next-intl";
import { useQuery } from "@apollo/client/react";
import { client } from "@/lib/apollo-client";
import {
	FULFILL_DELIVERY,
	LIST_EVENT_SPONSORSHIPS,
	LIST_WORKSPACE_SPONSORSHIPS,
	type SponsorshipTierConfig,
} from "@/lib/graphql/sponsorship";
import { statusLabel } from "@/components/sponsorship-intent-form";

export interface SponsorshipManagementProps {
	/** 目标：Event 级单场 / Workspace 级长期（event 级带 workspaceId：read policy
	 * 经 filter 提取租户，同 E-11 列表查询模式） */
	target:
		| { kind: "event"; id: string; workspaceId: string }
		| { kind: "workspace"; id: string };
	/** 当前档位配置（宿主解析后的 SponsorshipTierConfig 列表） */
	tiers: SponsorshipTierConfig[];
	/** 是否有管理权限（Owner/Admin）——无权限只读展示 */
	manage: boolean;
	/** 保存档位配置；返回成功与否（失败信息由组件内统一提示） */
	onSaveTiers: (tiers: SponsorshipTierConfig[]) => Promise<boolean>;
}

interface TierDraft {
	id: string;
	name: string;
	amount: string;
	benefits: string;
	exclusive: boolean;
}

function toDraft(tier: SponsorshipTierConfig): TierDraft {
	return {
		id: tier.id,
		name: tier.name,
		amount: tier.amountSuggestion === null ? "" : String(tier.amountSuggestion),
		benefits: tier.benefits.join("、"),
		exclusive: tier.exclusive,
	};
}

function fromDraft(draft: TierDraft): SponsorshipTierConfig | null {
	if (draft.name.trim() === "") return null;
	const amount = draft.amount.trim() === "" ? null : Number(draft.amount);
	return {
		id: draft.id,
		name: draft.name.trim(),
		amountSuggestion: Number.isFinite(amount) ? (amount as number) : null,
		benefits: draft.benefits
			.split(/[、,，]/)
			.map((b) => b.trim())
			.filter((b) => b !== ""),
		exclusive: draft.exclusive,
	};
}

export default function SponsorshipManagement({
	target,
	tiers,
	manage,
	onSaveTiers,
}: SponsorshipManagementProps) {
	const t = useTranslations("sponsorship");
	const [drafts, setDrafts] = useState<TierDraft[]>(tiers.map(toDraft));
	const [draftDirty, setDraftDirty] = useState(false);
	const [saving, setSaving] = useState(false);
	const [saveMessage, setSaveMessage] = useState<string | null>(null);
	const [proofInputs, setProofInputs] = useState<Record<string, string>>({});
	const [fulfilling, setFulfilling] = useState<string | null>(null);
	const [actionError, setActionError] = useState<string | null>(null);

	// 按目标分别查询（联合变量会破坏 TypedDocumentNode 推断，落入 DeepPartial 泛型）
	const eventQuery = useQuery(LIST_EVENT_SPONSORSHIPS, {
		variables: {
			eventId: target.kind === "event" ? target.id : "",
			workspaceId: target.kind === "event" ? target.workspaceId : "",
		},
		skip: target.kind !== "event" || !target.id,
	});

	const workspaceQuery = useQuery(LIST_WORKSPACE_SPONSORSHIPS, {
		variables: { workspaceId: target.kind === "workspace" ? target.id : "" },
		skip: target.kind !== "workspace" || !target.id,
	});

	const data = target.kind === "event" ? eventQuery.data : workspaceQuery.data;
	const refetch =
		target.kind === "event" ? eventQuery.refetch : workspaceQuery.refetch;

	const sponsorships = useMemo(
		() => data?.sponsorships?.results ?? [],
		[data],
	);

	function updateDraft(index: number, patch: Partial<TierDraft>) {
		setDrafts((prev) => prev.map((d, i) => (i === index ? { ...d, ...patch } : d)));
		setDraftDirty(true);
	}

	async function saveTiers() {
		const parsed = drafts
			.map(fromDraft)
			.filter((t): t is SponsorshipTierConfig => t !== null);
		if (parsed.length !== drafts.length) {
			setSaveMessage(t("tierNameRequired"));
			return;
		}
		setSaving(true);
		setSaveMessage(null);
		try {
			const ok = await onSaveTiers(parsed);
			setSaveMessage(ok ? t("tiersSaved") : t("saveFailed"));
			setDraftDirty(!ok);
		} catch (e: unknown) {
			setSaveMessage(e instanceof Error ? e.message : t("saveFailed"));
		} finally {
			setSaving(false);
		}
	}

	async function fulfill(deliveryId: string) {
		const note = (proofInputs[deliveryId] ?? "").trim();
		if (note === "") {
			setActionError(t("fulfillNoteRequired"));
			return;
		}
		setFulfilling(deliveryId);
		setActionError(null);
		try {
			const { data: d } = await client.mutate({
				mutation: FULFILL_DELIVERY,
				variables: { id: deliveryId, input: { proofNote: note } },
			});
			if (d?.fulfillDelivery?.result) {
				setProofInputs((prev) => ({ ...prev, [deliveryId]: "" }));
				await refetch();
			} else {
				setActionError(
					d?.fulfillDelivery?.errors?.[0]?.message ?? t("fulfillFailed"),
				);
			}
		} catch (e: unknown) {
			setActionError(e instanceof Error ? e.message : t("fulfillFailed"));
		} finally {
			setFulfilling(null);
		}
	}

	return (
		<section className="join-card !p-6">
			<h2 className="text-base font-semibold">{t("title")}</h2>

			{/* 档位配置 */}
			<div className="mt-3 border-t border-line pt-4">
				<h3 className="text-sm font-medium">{t("tiersTitle")}</h3>
				{manage ? (
					<div className="mt-2 grid gap-2">
						{drafts.map((draft, i) => (
							<div
								key={draft.id}
								className="grid gap-2 rounded-large border border-line bg-soft-2 p-3 sm:grid-cols-[1fr_auto_1fr_auto_auto]"
							>
								<input
									value={draft.name}
									onChange={(e) => updateDraft(i, { name: e.target.value })}
									placeholder={t("tierNamePlaceholder")}
									aria-label={t("tierNameAria")}
									className="rounded-large border border-line bg-white px-3 py-1.5 text-sm"
								/>
								<input
									value={draft.amount}
									onChange={(e) => updateDraft(i, { amount: e.target.value })}
									placeholder={t("amountPlaceholder")}
									aria-label={t("amountAria")}
									type="number"
									min={0}
									className="rounded-large border border-line bg-white px-3 py-1.5 text-sm"
								/>
								<input
									value={draft.benefits}
									onChange={(e) => updateDraft(i, { benefits: e.target.value })}
									placeholder={t("benefitsPlaceholder")}
									aria-label={t("benefitsAria")}
									className="rounded-large border border-line bg-white px-3 py-1.5 text-sm"
								/>
								<label className="flex items-center gap-1.5 text-[13px] text-ink-3">
									<input
										type="checkbox"
										checked={draft.exclusive}
										onChange={(e) => updateDraft(i, { exclusive: e.target.checked })}
									/>
									{t("exclusive")}
								</label>
								<button
									type="button"
									className="join-button !px-2 !py-1 text-[13px]"
									onClick={() => {
										setDrafts((prev) => prev.filter((_, j) => j !== i));
										setDraftDirty(true);
									}}
								>
									{t("delete")}
								</button>
							</div>
						))}
						<div className="flex gap-2">
							<button
								type="button"
								className="join-button"
								onClick={() => {
									setDrafts((prev) => [
										...prev,
										{ id: crypto.randomUUID(), name: "", amount: "", benefits: "", exclusive: false },
									]);
									setDraftDirty(true);
								}}
							>
								{t("addTier")}
							</button>
							<button
								type="button"
								className="join-button join-button--primary"
								disabled={saving || !draftDirty}
								onClick={() => void saveTiers()}
							>
								{saving ? t("saving") : t("saveTiers")}
							</button>
						</div>
						{saveMessage ? <p className="text-[13px] text-ink-3">{saveMessage}</p> : null}
					</div>
				) : (
					<div className="mt-2 grid gap-2">
						{tiers.map((tier) => (
							<div key={tier.id} className="rounded-large border border-line bg-soft-2 p-3 text-sm">
								<span className="font-medium">{tier.name}</span>
								{tier.exclusive ? <span className="ml-2 text-[12px] text-amber-700">{t("exclusive")}</span> : null}
								{tier.benefits.length > 0 ? (
									<p className="mt-0.5 text-[13px] text-ink-3">
										{t("benefitsLabel", { benefits: tier.benefits.join(" / ") })}
									</p>
								) : null}
							</div>
						))}
					</div>
				)}
			</div>

			{/* 赞助列表 + 履约账本 */}
			<div className="mt-4 border-t border-line pt-4">
				<h3 className="text-sm font-medium">{t("ledgerTitle")}</h3>
				{actionError ? (
					<p className="mt-2 text-[13px] text-ink-3" role="alert">
						{actionError}
					</p>
				) : null}
				{sponsorships.length === 0 ? (
					<p className="mt-2 text-[13px] text-ink-3">{t("noSponsorships")}</p>
				) : (
					<div className="mt-2 grid gap-2">
						{sponsorships.map((sponsorship) => (
							<div key={sponsorship.id} className="rounded-large border border-line bg-soft-2 p-3">
								<div className="flex flex-wrap items-center gap-2 text-sm">
									<strong>{sponsorship.companyName}</strong>
									{sponsorship.tierName ? (
										<span className="text-[13px] text-ink-3">{sponsorship.tierName}</span>
									) : null}
									{sponsorship.amount ? (
										<span className="text-[13px] text-ink-3">¥{sponsorship.amount}</span>
									) : null}
									<span
										className={
											"rounded-full px-2 py-0.5 text-[11px] " +
											(sponsorship.status === "active"
												? "bg-emerald-100 text-emerald-800"
												: sponsorship.status === "pending"
													? "bg-amber-100 text-amber-800"
													: "bg-soft-3 text-ink-3")
										}
									>
										{t(statusLabel(sponsorship.status))}
									</span>
								</div>
								<p className="mt-1 text-[13px] text-ink-3">
									{t("ledgerCount", {
										done: sponsorship.deliveries.filter((d) => d.fulfilledAt).length,
										total: sponsorship.deliveries.length,
									})}
								</p>
								{sponsorship.deliveries.length > 0 ? (
									<ul className="mt-2 grid gap-1.5">
										{sponsorship.deliveries.map((delivery) => (
											<li
												key={delivery.id}
												className="flex flex-wrap items-center gap-2 rounded-large border border-line bg-white px-3 py-1.5 text-[13px]"
											>
												<span className={delivery.fulfilledAt ? "text-ink-3" : ""}>
													{delivery.fulfilledAt ? "✓" : "○"} {delivery.benefit}
													{delivery.exclusive ? t("deliveryExclusive") : ""}
												</span>
												{delivery.fulfilledAt ? (
													<span className="ml-auto text-ink-3">
														{t("fulfilledNote", { note: delivery.proofNote ?? "—" })}
													</span>
												) : manage ? (
													<span className="ml-auto flex gap-2">
														<input
															value={proofInputs[delivery.id] ?? ""}
															onChange={(e) =>
																setProofInputs((prev) => ({
																	...prev,
																	[delivery.id]: e.target.value,
																}))
															}
															placeholder={t("proofPlaceholder")}
															aria-label={t("proofAria")}
															className="rounded-large border border-line px-2 py-1 text-[12px]"
														/>
														<button
															type="button"
															className="join-button join-button--primary !px-2 !py-1 text-[12px]"
															disabled={fulfilling === delivery.id}
															onClick={() => void fulfill(delivery.id)}
														>
															{fulfilling === delivery.id ? t("fulfilling") : t("fulfill")}
														</button>
													</span>
												) : (
													<span className="ml-auto text-ink-3">{t("notFulfilled")}</span>
												)}
											</li>
										))}
									</ul>
								) : null}
							</div>
						))}
					</div>
				)}
			</div>
		</section>
	);
}
