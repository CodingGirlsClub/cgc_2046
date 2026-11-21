import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { BigIntScalar } from "./llm-gateway";

export type LlmProviderProtocol = "openai_compatible" | "anthropic";

export interface AdminLlmProviderApiKey {
	id: string;
	providerId: string;
	label: string;
	keyPreview: string;
	enabled: boolean;
	insertedAt: string;
}

export interface AdminLlmProviderModel {
	id: string;
	providerId: string;
	modelId: string;
	upstreamModelId: string;
	displayName: string;
	enabled: boolean;
	contextWindow: number;
	maxOutputTokens: number;
	supportsThinking: boolean;
	supportsTools: boolean;
	supportsImages: boolean;
	reasoningEfforts: string[];
	cacheHitPriceMc: BigIntScalar;
	cacheMissPriceMc: BigIntScalar;
	outputPriceMc: BigIntScalar;
	markupRatio: number;
	insertedAt: string;
}

export interface AdminLlmProvider {
	id: string;
	name: string;
	slug: string;
	protocol: LlmProviderProtocol | string;
	baseUrl: string;
	chatPath?: string | null;
	modelsPath?: string | null;
	priority: number;
	offPeakDiscountEnabled: boolean;
	enabled: boolean;
	apiKeys: AdminLlmProviderApiKey[];
	models: AdminLlmProviderModel[];
	insertedAt: string;
	updatedAt: string;
}

export interface LlmUpstreamDiscoveredModel {
	modelId: string;
	upstreamModelId: string;
	displayName: string;
	contextWindow: number;
	maxOutputTokens: number;
	supportsThinking: boolean;
	supportsTools: boolean;
	supportsImages: boolean;
	reasoningEfforts: string[];
	cacheHitPriceMc: BigIntScalar;
	cacheMissPriceMc: BigIntScalar;
	outputPriceMc: BigIntScalar;
	markupRatio: number;
	presetMatched: boolean;
}

export interface LlmModelPricingPreset {
	modelId: string;
	displayName: string;
	contextWindow: number;
	maxOutputTokens: number;
	supportsThinking: boolean;
	supportsTools: boolean;
	supportsImages: boolean;
	reasoningEfforts: string[];
	cacheHitPriceMc: BigIntScalar;
	cacheMissPriceMc: BigIntScalar;
	outputPriceMc: BigIntScalar;
	markupRatio: number;
}

export interface AdminLlmProviderInput {
	name: string;
	slug: string;
	protocol: LlmProviderProtocol | string;
	baseUrl: string;
	chatPath?: string | null;
	modelsPath?: string | null;
	priority?: number | null;
	offPeakDiscountEnabled?: boolean | null;
	enabled?: boolean | null;
}

export interface AdminLlmProviderModelInput {
	modelId: string;
	upstreamModelId?: string | null;
	displayName: string;
	enabled?: boolean | null;
	contextWindow: number;
	maxOutputTokens: number;
	supportsThinking?: boolean | null;
	supportsTools?: boolean | null;
	supportsImages?: boolean | null;
	reasoningEfforts?: string[] | null;
	cacheHitPriceMc: BigIntScalar;
	cacheMissPriceMc: BigIntScalar;
	outputPriceMc: BigIntScalar;
	markupRatio?: number | null;
}

export const ADMIN_LLM_PROVIDERS: TypedDocumentNode<
	{ adminLlmProviders: AdminLlmProvider[] },
	Record<string, never>
> = gql`
	query AdminLlmProviders {
		adminLlmProviders {
			id
			name
			slug
			protocol
			baseUrl
			chatPath
			modelsPath
			priority
			offPeakDiscountEnabled
			enabled
			apiKeys {
				id
				providerId
				label
				keyPreview
				enabled
				insertedAt
			}
			models {
				id
				providerId
				modelId
				upstreamModelId
				displayName
				enabled
				contextWindow
				maxOutputTokens
				supportsThinking
				supportsTools
				supportsImages
				reasoningEfforts
				cacheHitPriceMc
				cacheMissPriceMc
				outputPriceMc
				markupRatio
				insertedAt
			}
			insertedAt
			updatedAt
		}
	}
`;

export const ADMIN_LLM_PRICING_PRESETS: TypedDocumentNode<
	{ adminLlmPricingPresets: LlmModelPricingPreset[] },
	Record<string, never>
> = gql`
	query AdminLlmPricingPresets {
		adminLlmPricingPresets {
			modelId
			displayName
			contextWindow
			maxOutputTokens
			supportsThinking
			supportsTools
			supportsImages
			reasoningEfforts
			cacheHitPriceMc
			cacheMissPriceMc
			outputPriceMc
			markupRatio
		}
	}
`;

export const ADMIN_CREATE_LLM_PROVIDER: TypedDocumentNode<
	{ adminCreateLlmProvider: AdminLlmProvider | null },
	{ input: AdminLlmProviderInput }
> = gql`
	mutation AdminCreateLlmProvider($input: AdminLlmProviderInput!) {
		adminCreateLlmProvider(input: $input) {
			id
			name
			slug
			protocol
			baseUrl
			chatPath
			modelsPath
			priority
			offPeakDiscountEnabled
			enabled
		}
	}
`;

export const ADMIN_UPDATE_LLM_PROVIDER: TypedDocumentNode<
	{ adminUpdateLlmProvider: AdminLlmProvider | null },
	{ id: string; input: AdminLlmProviderInput }
> = gql`
	mutation AdminUpdateLlmProvider($id: ID!, $input: AdminLlmProviderInput!) {
		adminUpdateLlmProvider(id: $id, input: $input) {
			id
			name
			slug
			protocol
			baseUrl
			chatPath
			modelsPath
			priority
			offPeakDiscountEnabled
			enabled
		}
	}
`;

export const ADMIN_DELETE_LLM_PROVIDER: TypedDocumentNode<
	{ adminDeleteLlmProvider: boolean },
	{ id: string }
> = gql`
	mutation AdminDeleteLlmProvider($id: ID!) {
		adminDeleteLlmProvider(id: $id)
	}
`;

export const ADMIN_ADD_LLM_PROVIDER_API_KEY: TypedDocumentNode<
	{ adminAddLlmProviderApiKey: AdminLlmProviderApiKey | null },
	{ providerId: string; label: string; apiKey: string }
> = gql`
	mutation AdminAddLlmProviderApiKey(
		$providerId: ID!
		$label: String!
		$apiKey: String!
	) {
		adminAddLlmProviderApiKey(
			providerId: $providerId
			label: $label
			apiKey: $apiKey
		) {
			id
			providerId
			label
			keyPreview
			enabled
			insertedAt
		}
	}
`;

export const ADMIN_UPDATE_LLM_PROVIDER_API_KEY: TypedDocumentNode<
	{ adminUpdateLlmProviderApiKey: AdminLlmProviderApiKey | null },
	{ id: string; label?: string | null; enabled?: boolean | null }
> = gql`
	mutation AdminUpdateLlmProviderApiKey(
		$id: ID!
		$label: String
		$enabled: Boolean
	) {
		adminUpdateLlmProviderApiKey(id: $id, label: $label, enabled: $enabled) {
			id
			providerId
			label
			keyPreview
			enabled
			insertedAt
		}
	}
`;

export const ADMIN_DELETE_LLM_PROVIDER_API_KEY: TypedDocumentNode<
	{ adminDeleteLlmProviderApiKey: boolean },
	{ id: string }
> = gql`
	mutation AdminDeleteLlmProviderApiKey($id: ID!) {
		adminDeleteLlmProviderApiKey(id: $id)
	}
`;

export const ADMIN_FETCH_LLM_PROVIDER_UPSTREAM_MODELS: TypedDocumentNode<
	{ adminFetchLlmProviderUpstreamModels: LlmUpstreamDiscoveredModel[] },
	{ providerId: string; apiKey?: string | null }
> = gql`
	mutation AdminFetchLlmProviderUpstreamModels($providerId: ID!, $apiKey: String) {
		adminFetchLlmProviderUpstreamModels(providerId: $providerId, apiKey: $apiKey) {
			modelId
			upstreamModelId
			displayName
			contextWindow
			maxOutputTokens
			supportsThinking
			supportsTools
			supportsImages
			reasoningEfforts
			cacheHitPriceMc
			cacheMissPriceMc
			outputPriceMc
			markupRatio
			presetMatched
		}
	}
`;

export const ADMIN_SAVE_LLM_PROVIDER_MODELS: TypedDocumentNode<
	{ adminSaveLlmProviderModels: AdminLlmProviderModel[] },
	{ providerId: string; models: AdminLlmProviderModelInput[] }
> = gql`
	mutation AdminSaveLlmProviderModels(
		$providerId: ID!
		$models: [AdminLlmProviderModelInput!]!
	) {
		adminSaveLlmProviderModels(providerId: $providerId, models: $models) {
			id
			providerId
			modelId
			upstreamModelId
			displayName
			enabled
			contextWindow
			maxOutputTokens
			supportsThinking
			supportsTools
			supportsImages
			reasoningEfforts
			cacheHitPriceMc
			cacheMissPriceMc
			outputPriceMc
			markupRatio
			insertedAt
		}
	}
`;

export const ADMIN_DELETE_LLM_PROVIDER_MODEL: TypedDocumentNode<
	{ adminDeleteLlmProviderModel: boolean },
	{ id: string }
> = gql`
	mutation AdminDeleteLlmProviderModel($id: ID!) {
		adminDeleteLlmProviderModel(id: $id)
	}
`;
