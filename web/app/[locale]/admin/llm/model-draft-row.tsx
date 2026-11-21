"use client";

import { useTranslations } from "next-intl";
import { type ModelDraft, userPricePreview } from "./model-draft-helpers";

interface ModelDraftRowProps {
	draft: ModelDraft;
	deleting: boolean;
	saving?: boolean;
	onUpdate: (patch: Partial<ModelDraft>) => void;
	onDelete: () => void;
}

export default function ModelDraftRow({
	draft,
	deleting,
	saving = false,
	onUpdate,
	onDelete,
}: ModelDraftRowProps) {
	const t = useTranslations("adminLlm");

	return (
		<div
			className="grid gap-3 rounded-lg border border-line bg-surface p-3 text-xs"
			data-testid={`provider-model-row-${draft.modelId}`}
		>
			<div className="flex flex-wrap items-center justify-between gap-2">
				<div className="flex flex-wrap items-center gap-2">
					<span className="font-mono font-semibold text-ink">
						{draft.modelId}
					</span>
					<label className="flex items-center gap-1 text-ink-2">
						<input
							type="checkbox"
							checked={draft.enabled}
							onChange={(e) => onUpdate({ enabled: e.target.checked })}
						/>
						<span>{t("statusEnabled")}</span>
					</label>
				</div>
				<button
					type="button"
					disabled={deleting || saving}
					onClick={onDelete}
					className="l-btn-outline text-xs text-red-400"
				>
					{t("deleteAction")}
				</button>
			</div>

			<div className="grid gap-2 sm:grid-cols-4">
				<label className="grid gap-1 text-ink-2">
					<span>{t("modelDisplayName")}</span>
					<input
						type="text"
						value={draft.displayName}
						onChange={(e) => onUpdate({ displayName: e.target.value })}
						className="l-input text-xs"
					/>
				</label>
				<label className="grid gap-1 text-ink-2">
					<span>{t("modelUpstreamId")}</span>
					<input
						type="text"
						value={draft.upstreamModelId}
						onChange={(e) => onUpdate({ upstreamModelId: e.target.value })}
						className="l-input font-mono text-xs"
					/>
				</label>
				<label className="grid gap-1 text-ink-2">
					<span>{t("modelContextWindow")}</span>
					<input
						type="number"
						min={1}
						value={draft.contextWindow}
						onChange={(e) => onUpdate({ contextWindow: e.target.value })}
						className="l-input text-xs"
					/>
				</label>
				<label className="grid gap-1 text-ink-2">
					<span>{t("modelMaxOutput")}</span>
					<input
						type="number"
						min={1}
						value={draft.maxOutputTokens}
						onChange={(e) => onUpdate({ maxOutputTokens: e.target.value })}
						className="l-input text-xs"
					/>
				</label>
			</div>

			<div className="grid gap-2 sm:grid-cols-4">
				<label className="grid gap-1 text-ink-2">
					<span>{t("modelCacheMissPrice")}</span>
					<input
						type="text"
						inputMode="decimal"
						value={draft.cacheMissCny}
						onChange={(e) => onUpdate({ cacheMissCny: e.target.value })}
						className="l-input font-mono text-xs"
					/>
					<span className="text-[11px] text-ink-3">
						{t("userPriceHint", {
							price: userPricePreview(draft.cacheMissCny, draft.markupRatio),
						})}
					</span>
				</label>
				<label className="grid gap-1 text-ink-2">
					<span>{t("modelCacheHitPrice")}</span>
					<input
						type="text"
						inputMode="decimal"
						value={draft.cacheHitCny}
						onChange={(e) => onUpdate({ cacheHitCny: e.target.value })}
						className="l-input font-mono text-xs"
					/>
					<span className="text-[11px] text-ink-3">
						{t("userPriceHint", {
							price: userPricePreview(draft.cacheHitCny, draft.markupRatio),
						})}
					</span>
				</label>
				<label className="grid gap-1 text-ink-2">
					<span>{t("modelOutputPrice")}</span>
					<input
						type="text"
						inputMode="decimal"
						value={draft.outputCny}
						onChange={(e) => onUpdate({ outputCny: e.target.value })}
						className="l-input font-mono text-xs"
					/>
					<span className="text-[11px] text-ink-3">
						{t("userPriceHint", {
							price: userPricePreview(draft.outputCny, draft.markupRatio),
						})}
					</span>
				</label>
				<label className="grid gap-1 text-ink-2">
					<span>{t("modelMarkupRatio")}</span>
					<input
						type="number"
						step="0.1"
						min={1}
						value={draft.markupRatio}
						onChange={(e) => onUpdate({ markupRatio: e.target.value })}
						className="l-input font-mono text-xs"
					/>
				</label>
			</div>

			<div className="flex flex-wrap items-center gap-4">
				<label className="flex items-center gap-1.5 text-ink-2">
					<input
						type="checkbox"
						checked={draft.supportsThinking}
						onChange={(e) => onUpdate({ supportsThinking: e.target.checked })}
					/>
					<span>{t("capThinking")}</span>
				</label>
				<label className="flex items-center gap-1.5 text-ink-2">
					<input
						type="checkbox"
						checked={draft.supportsTools}
						onChange={(e) => onUpdate({ supportsTools: e.target.checked })}
					/>
					<span>{t("capTools")}</span>
				</label>
				<label className="flex items-center gap-1.5 text-ink-2">
					<input
						type="checkbox"
						checked={draft.supportsImages}
						onChange={(e) => onUpdate({ supportsImages: e.target.checked })}
					/>
					<span>{t("capImages")}</span>
				</label>
				<label className="flex items-center gap-1.5 text-ink-2">
					<span>{t("capEfforts")}</span>
					<input
						type="text"
						value={draft.reasoningEffortsText}
						onChange={(e) => onUpdate({ reasoningEffortsText: e.target.value })}
						placeholder="low, medium, high"
						className="l-input w-44 text-xs"
					/>
				</label>
			</div>
		</div>
	);
}
