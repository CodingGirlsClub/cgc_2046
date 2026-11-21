import type {
	AdminLlmProviderModel,
	LlmModelPricingPreset,
	LlmUpstreamDiscoveredModel,
} from "@/lib/graphql/llm-providers";
import {
	formatMcAsCny,
	formatMcToPlainCny,
	parseNonNegativeCnyInputToMc,
} from "@/lib/llm-credits";

export interface ModelDraft {
	savedId?: string;
	modelId: string;
	upstreamModelId: string;
	displayName: string;
	enabled: boolean;
	contextWindow: string;
	maxOutputTokens: string;
	supportsThinking: boolean;
	supportsTools: boolean;
	supportsImages: boolean;
	reasoningEffortsText: string;
	cacheHitCny: string;
	cacheMissCny: string;
	outputCny: string;
	markupRatio: string;
}

export function fromSavedModel(model: AdminLlmProviderModel): ModelDraft {
	return {
		savedId: model.id,
		modelId: model.modelId,
		upstreamModelId: model.upstreamModelId,
		displayName: model.displayName,
		enabled: model.enabled,
		contextWindow: String(model.contextWindow),
		maxOutputTokens: String(model.maxOutputTokens),
		supportsThinking: model.supportsThinking,
		supportsTools: model.supportsTools,
		supportsImages: model.supportsImages,
		reasoningEffortsText: model.reasoningEfforts.join(", "),
		cacheHitCny: formatMcToPlainCny(model.cacheHitPriceMc),
		cacheMissCny: formatMcToPlainCny(model.cacheMissPriceMc),
		outputCny: formatMcToPlainCny(model.outputPriceMc),
		markupRatio: String(model.markupRatio),
	};
}

export function fromDiscoveredModel(
	model: LlmUpstreamDiscoveredModel,
): ModelDraft {
	return {
		modelId: model.modelId,
		upstreamModelId: model.upstreamModelId,
		displayName: model.displayName,
		enabled: true,
		contextWindow: String(model.contextWindow),
		maxOutputTokens: String(model.maxOutputTokens),
		supportsThinking: model.supportsThinking,
		supportsTools: model.supportsTools,
		supportsImages: model.supportsImages,
		reasoningEffortsText: model.reasoningEfforts.join(", "),
		cacheHitCny: formatMcToPlainCny(model.cacheHitPriceMc),
		cacheMissCny: formatMcToPlainCny(model.cacheMissPriceMc),
		outputCny: formatMcToPlainCny(model.outputPriceMc),
		markupRatio: String(model.markupRatio),
	};
}

export function fromPreset(
	modelId: string,
	upstreamModelId: string,
	displayName: string,
	preset?: LlmModelPricingPreset,
): ModelDraft {
	return {
		modelId,
		upstreamModelId: upstreamModelId || modelId,
		displayName: displayName || preset?.displayName || modelId,
		enabled: true,
		contextWindow: String(preset?.contextWindow ?? 128000),
		maxOutputTokens: String(preset?.maxOutputTokens ?? 8192),
		supportsThinking: preset?.supportsThinking ?? false,
		supportsTools: preset?.supportsTools ?? true,
		supportsImages: preset?.supportsImages ?? false,
		reasoningEffortsText: (preset?.reasoningEfforts ?? []).join(", "),
		cacheHitCny: formatMcToPlainCny(preset?.cacheHitPriceMc ?? 0),
		cacheMissCny: formatMcToPlainCny(preset?.cacheMissPriceMc ?? 0),
		outputCny: formatMcToPlainCny(preset?.outputPriceMc ?? 0),
		markupRatio: String(preset?.markupRatio ?? 1.5),
	};
}

export function findMatchingPreset(
	modelId: string,
	presets: LlmModelPricingPreset[],
): LlmModelPricingPreset | undefined {
	const needle = modelId.trim().toLowerCase();
	if (!needle) return undefined;
	return (
		presets.find((p) => p.modelId.toLowerCase() === needle) ??
		presets.find(
			(p) =>
				needle.startsWith(`${p.modelId.toLowerCase()}-`) ||
				needle.startsWith(`${p.modelId.toLowerCase()}:`),
		)
	);
}

export function userPricePreview(costCny: string, markupStr: string): string {
	const costMc = parseNonNegativeCnyInputToMc(costCny);
	const markup = Number(markupStr);
	if (costMc === null || !Number.isFinite(markup) || markup < 1) return "—";
	const scaled = (costMc * BigInt(Math.round(markup * 1000))) / BigInt(1000);
	return formatMcAsCny(scaled, { decimals: 2 });
}
