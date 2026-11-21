"use client";

import { useMemo, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import {
	ADMIN_DELETE_LLM_PROVIDER_MODEL,
	ADMIN_FETCH_LLM_PROVIDER_UPSTREAM_MODELS,
	ADMIN_SAVE_LLM_PROVIDER_MODELS,
	type AdminLlmProvider,
	type AdminLlmProviderModelInput,
	type LlmModelPricingPreset,
	type LlmUpstreamDiscoveredModel,
} from "@/lib/graphql/llm-providers";
import { parseNonNegativeCnyInputToMc, toBigIntMc } from "@/lib/llm-credits";
import {
	findMatchingPreset,
	fromDiscoveredModel,
	fromPreset,
	fromSavedModel,
	type ModelDraft,
} from "./model-draft-helpers";
import ModelDraftRow from "./model-draft-row";

interface ProviderModelsSectionProps {
	provider: AdminLlmProvider;
	presets: LlmModelPricingPreset[];
	onChanged: () => Promise<void>;
}

function errorMessage(err: unknown, fallback: string): string {
	return err instanceof Error && err.message ? err.message : fallback;
}

export default function ProviderModelsSection({
	provider,
	presets,
	onChanged,
}: ProviderModelsSectionProps) {
	const t = useTranslations("adminLlm");
	const [drafts, setDrafts] = useState<ModelDraft[]>(() =>
		provider.models.map(fromSavedModel),
	);
	const [overrideKey, setOverrideKey] = useState("");
	const [fetching, setFetching] = useState(false);
	const [discovered, setDiscovered] = useState<LlmUpstreamDiscoveredModel[] | null>(
		null,
	);
	const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
	const [searchTerm, setSearchTerm] = useState("");
	const [manualModelId, setManualModelId] = useState("");
	const [manualUpstreamId, setManualUpstreamId] = useState("");
	const [manualDisplayName, setManualDisplayName] = useState("");
	const [saving, setSaving] = useState(false);
	const [deletingIds, setDeletingIds] = useState<Set<string>>(() => new Set());
	const [error, setError] = useState<string | null>(null);
	const [status, setStatus] = useState<string | null>(null);

	const filteredDiscovered = useMemo(() => {
		if (!discovered) return [];
		const q = searchTerm.trim().toLowerCase();
		if (!q) return discovered;
		return discovered.filter(
			(item) =>
				item.modelId.toLowerCase().includes(q) ||
				item.displayName.toLowerCase().includes(q),
		);
	}, [discovered, searchTerm]);

	async function handleFetchUpstream() {
		setError(null);
		setStatus(null);
		setFetching(true);
		try {
			const { data } = await client.mutate({
				mutation: ADMIN_FETCH_LLM_PROVIDER_UPSTREAM_MODELS,
				variables: {
					providerId: provider.id,
					apiKey: overrideKey.trim() ? overrideKey.trim() : null,
				},
			});
			const list = data?.adminFetchLlmProviderUpstreamModels ?? [];
			setDiscovered(list);
			const existingSet = new Set(drafts.map((d) => d.modelId));
			setSelectedIds(
				new Set(list.filter((m) => !existingSet.has(m.modelId)).map((m) => m.modelId)),
			);
			setOverrideKey("");
		} catch (err) {
			setError(errorMessage(err, t("fetchModelsFailed")));
		} finally {
			setFetching(false);
		}
	}

	function handleAddSelectedDiscovered() {
		if (saving || !discovered) return;
		const existing = new Set(drafts.map((d) => d.modelId));
		const additions = discovered
			.filter((item) => selectedIds.has(item.modelId) && !existing.has(item.modelId))
			.map(fromDiscoveredModel);
		if (additions.length > 0) {
			setDrafts((prev) => [...prev, ...additions]);
			setStatus(t("addedDiscoveredCount", { count: additions.length }));
		}
		setDiscovered(null);
	}

	function handleAddManual() {
		if (saving) return;
		setError(null);
		setStatus(null);
		const modelId = manualModelId.trim();
		if (!modelId) {
			setError(t("validationModelId"));
			return;
		}
		if (drafts.some((d) => d.modelId === modelId)) {
			setError(t("validationModelDuplicate"));
			return;
		}
		const preset = findMatchingPreset(modelId, presets);
		const nextDraft = fromPreset(
			modelId,
			manualUpstreamId.trim(),
			manualDisplayName.trim(),
			preset,
		);
		setDrafts((prev) => [...prev, nextDraft]);
		setManualModelId("");
		setManualUpstreamId("");
		setManualDisplayName("");
	}

	function updateDraft(modelId: string, patch: Partial<ModelDraft>) {
		if (saving) return;
		setDrafts((prev) =>
			prev.map((item) => (item.modelId === modelId ? { ...item, ...patch } : item)),
		);
	}

	async function handleDeleteRow(target: ModelDraft) {
		if (saving) return;
		const { modelId, savedId } = target;
		setError(null);
		setStatus(null);
		if (!savedId) {
			setDrafts((prev) => prev.filter((item) => item.modelId !== modelId));
			return;
		}
		if (deletingIds.has(savedId)) return;
		setDeletingIds((prev) => new Set(prev).add(savedId));
		try {
			await client.mutate({
				mutation: ADMIN_DELETE_LLM_PROVIDER_MODEL,
				variables: { id: savedId },
			});
			setDrafts((prev) => prev.filter((item) => item.savedId !== savedId));
			await onChanged();
		} catch (err) {
			setError(errorMessage(err, t("deleteModelFailed")));
		} finally {
			setDeletingIds((prev) => {
				const next = new Set(prev);
				next.delete(savedId);
				return next;
			});
		}
	}

	async function handleSaveAll() {
		if (saving || deletingIds.size > 0) return;
		setError(null);
		setStatus(null);

		const inputs: AdminLlmProviderModelInput[] = [];
		for (const draft of drafts) {
			const ctx = Number(draft.contextWindow);
			const outMax = Number(draft.maxOutputTokens);
			const hitMc = parseNonNegativeCnyInputToMc(draft.cacheHitCny);
			const missMc = parseNonNegativeCnyInputToMc(draft.cacheMissCny);
			const outputMc = parseNonNegativeCnyInputToMc(draft.outputCny);
			const markup = Number(draft.markupRatio);

			if (
				!draft.modelId.trim() ||
				!draft.displayName.trim() ||
				!Number.isInteger(ctx) ||
				ctx <= 0 ||
				!Number.isInteger(outMax) ||
				outMax <= 0 ||
				hitMc === null ||
				missMc === null ||
				outputMc === null ||
				!Number.isFinite(markup) ||
				markup < 1
			) {
				setError(t("validationModelRow", { modelId: draft.modelId || "?" }));
				return;
			}

			inputs.push({
				modelId: draft.modelId.trim(),
				upstreamModelId: draft.upstreamModelId.trim() || draft.modelId.trim(),
				displayName: draft.displayName.trim(),
				enabled: draft.enabled,
				contextWindow: ctx,
				maxOutputTokens: outMax,
				supportsThinking: draft.supportsThinking,
				supportsTools: draft.supportsTools,
				supportsImages: draft.supportsImages,
				reasoningEfforts: draft.reasoningEffortsText
					.split(",")
					.map((s) => s.trim())
					.filter(Boolean),
				cacheHitPriceMc: toBigIntMc(hitMc).toString(),
				cacheMissPriceMc: toBigIntMc(missMc).toString(),
				outputPriceMc: toBigIntMc(outputMc).toString(),
				markupRatio: markup,
			});
		}

		setSaving(true);
		try {
			const { data } = await client.mutate({
				mutation: ADMIN_SAVE_LLM_PROVIDER_MODELS,
				variables: { providerId: provider.id, models: inputs },
			});
			if (data?.adminSaveLlmProviderModels) {
				setDrafts(data.adminSaveLlmProviderModels.map(fromSavedModel));
			}
			setStatus(t("saveModelsSuccess", { count: inputs.length }));
			await onChanged();
		} catch (err) {
			setError(errorMessage(err, t("saveModelsFailed")));
		} finally {
			setSaving(false);
		}
	}

	return (
		<div className="grid gap-3 border-t border-line pt-4">
			<div className="flex flex-wrap items-center justify-between gap-2">
				<h4 className="text-xs font-semibold uppercase tracking-wide text-ink-2">
					{t("modelsSectionTitle")} ({drafts.length})
				</h4>
				<div className="flex flex-wrap items-center gap-2">
					<input
						type="password"
						autoComplete="off"
						value={overrideKey}
						onChange={(e) => setOverrideKey(e.target.value)}
						placeholder={t("fetchOverrideKeyPlaceholder")}
						className="l-input max-w-[220px] text-xs"
					/>
					<button
						type="button"
						disabled={fetching}
						onClick={() => void handleFetchUpstream()}
						className="l-btn-outline text-xs"
					>
						{fetching ? t("fetchingModels") : t("fetchUpstreamModels")}
					</button>
				</div>
			</div>

			{discovered && (
				<div
					className="grid gap-2 rounded-lg border border-line bg-surface p-3"
					data-testid={`discovered-models-${provider.slug}`}
				>
					<div className="flex flex-wrap items-center justify-between gap-2">
						<input
							type="text"
							value={searchTerm}
							onChange={(e) => setSearchTerm(e.target.value)}
							placeholder={t("searchDiscoveredPlaceholder")}
							className="l-input max-w-[260px] text-xs"
						/>
						<div className="flex items-center gap-2">
							<button
								type="button"
								onClick={() =>
									setSelectedIds(new Set(filteredDiscovered.map((m) => m.modelId)))
								}
								className="l-btn-outline text-xs"
							>
								{t("selectAll")}
							</button>
							<button
								type="button"
								onClick={() => setSelectedIds(new Set())}
								className="l-btn-outline text-xs"
							>
								{t("selectNone")}
							</button>
							<button
								type="button"
								disabled={saving}
								onClick={handleAddSelectedDiscovered}
								className="l-btn-primary text-xs"
							>
								{t("addSelectedModels", { count: selectedIds.size })}
							</button>
							<button
								type="button"
								onClick={() => setDiscovered(null)}
								className="l-btn-outline text-xs"
							>
								{t("cancelAction")}
							</button>
						</div>
					</div>
					{filteredDiscovered.length === 0 ? (
						<p className="text-xs text-ink-3">{t("discoveredEmpty")}</p>
					) : (
						<div className="grid max-h-56 gap-1 overflow-y-auto sm:grid-cols-2">
							{filteredDiscovered.map((item) => (
								<label
									key={item.modelId}
									className="flex cursor-pointer items-center justify-between gap-2 rounded border border-line px-2 py-1.5 text-xs hover:bg-soft"
								>
									<span className="flex items-center gap-2">
										<input
											type="checkbox"
											checked={selectedIds.has(item.modelId)}
											onChange={(e) => {
												setSelectedIds((prev) => {
													const next = new Set(prev);
													if (e.target.checked) next.add(item.modelId);
													else next.delete(item.modelId);
													return next;
												});
											}}
										/>
										<span className="font-mono text-ink">{item.modelId}</span>
									</span>
									<span className="text-ink-3">
										{item.presetMatched
											? t("presetMatchedBadge")
											: t("presetUnmatchedBadge")}
									</span>
								</label>
							))}
						</div>
					)}
				</div>
			)}

			<div className="grid gap-2 rounded-lg border border-dashed border-line p-3 sm:grid-cols-[1.2fr_1.2fr_1.2fr_auto] sm:items-end">
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("manualModelIdLabel")}</span>
					<input
						type="text"
						value={manualModelId}
						onChange={(e) => setManualModelId(e.target.value)}
						placeholder="deepseek-chat / claude-sonnet-4-5"
						className="l-input text-xs"
					/>
				</label>
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("manualUpstreamIdLabel")}</span>
					<input
						type="text"
						value={manualUpstreamId}
						onChange={(e) => setManualUpstreamId(e.target.value)}
						placeholder={t("manualUpstreamPlaceholder")}
						className="l-input text-xs"
					/>
				</label>
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("manualDisplayNameLabel")}</span>
					<input
						type="text"
						value={manualDisplayName}
						onChange={(e) => setManualDisplayName(e.target.value)}
						placeholder={t("manualDisplayPlaceholder")}
						className="l-input text-xs"
					/>
				</label>
				<button
					type="button"
					disabled={saving}
					onClick={handleAddManual}
					className="l-btn-outline text-xs"
				>
					{t("addManualModel")}
				</button>
			</div>

			{drafts.length === 0 ? (
				<p className="text-xs text-ink-3">{t("modelsEmpty")}</p>
			) : (
				<div className="grid gap-3">
					{drafts.map((draft) => (
						<ModelDraftRow
							key={draft.modelId}
							draft={draft}
							deleting={Boolean(draft.savedId && deletingIds.has(draft.savedId))}
							saving={saving}
							onUpdate={(patch) => updateDraft(draft.modelId, patch)}
							onDelete={() => void handleDeleteRow(draft)}
						/>
					))}
				</div>
			)}

			{error && (
				<p role="alert" className="text-xs text-red-400">
					{error}
				</p>
			)}
			{status && (
				<p role="status" className="text-xs text-emerald-400">
					{status}
				</p>
			)}

			<div className="flex justify-end">
				<button
					type="button"
					disabled={saving || deletingIds.size > 0 || drafts.length === 0}
					onClick={() => void handleSaveAll()}
					className="l-btn-primary text-xs"
				>
					{saving ? t("submitting") : t("saveModelsSubmit")}
				</button>
			</div>
		</div>
	);
}
