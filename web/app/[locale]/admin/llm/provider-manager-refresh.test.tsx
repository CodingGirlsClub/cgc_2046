import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import {
	ADMIN_DELETE_LLM_PROVIDER_MODEL,
	ADMIN_LLM_PRICING_PRESETS,
	ADMIN_LLM_PROVIDERS,
	ADMIN_UPDATE_LLM_PROVIDER_API_KEY,
	type AdminLlmProvider,
	type LlmModelPricingPreset,
} from "@/lib/graphql/llm-providers";
import ProviderManager from "./provider-manager";

const { queryMock, mutateMock } = vi.hoisted(() => ({
	queryMock: vi.fn(),
	mutateMock: vi.fn(),
}));

vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: queryMock,
		mutate: mutateMock,
	},
}));

const SAMPLE_PRESETS: LlmModelPricingPreset[] = [
	{
		modelId: "deepseek-chat",
		displayName: "DeepSeek Chat",
		contextWindow: 128_000,
		maxOutputTokens: 8_192,
		supportsThinking: false,
		supportsTools: true,
		supportsImages: false,
		reasoningEfforts: [],
		cacheHitPriceMc: "200000",
		cacheMissPriceMc: "2000000",
		outputPriceMc: "3000000",
		markupRatio: 1.5,
	},
];

function makeProvidersFixture(): [AdminLlmProvider, AdminLlmProvider] {
	return [
		{
			id: "prov-1",
			name: "DeepSeek",
			slug: "deepseek",
			protocol: "openai_compatible",
			baseUrl: "https://api.deepseek.com",
			chatPath: null,
			modelsPath: null,
			priority: 100,
			offPeakDiscountEnabled: true,
			enabled: true,
			apiKeys: [
				{
					id: "key-1",
					providerId: "prov-1",
					label: "主号 Key",
					keyPreview: "sk-1234…abcd",
					enabled: true,
					insertedAt: "2026-11-21T00:00:00Z",
				},
			],
			models: [
				{
					id: "model-ds-1",
					providerId: "prov-1",
					modelId: "deepseek-chat",
					upstreamModelId: "deepseek-chat",
					displayName: "DeepSeek Chat",
					enabled: true,
					contextWindow: 128_000,
					maxOutputTokens: 8_192,
					supportsThinking: false,
					supportsTools: true,
					supportsImages: false,
					reasoningEfforts: [],
					cacheHitPriceMc: "200000",
					cacheMissPriceMc: "2000000",
					outputPriceMc: "3000000",
					markupRatio: 1.5,
					insertedAt: "2026-11-21T00:00:00Z",
				},
			],
			insertedAt: "2026-11-21T00:00:00Z",
			updatedAt: "2026-11-21T00:00:00Z",
		},
		{
			id: "prov-2",
			name: "Anthropic",
			slug: "anthropic",
			protocol: "anthropic",
			baseUrl: "https://api.anthropic.com",
			chatPath: null,
			modelsPath: null,
			priority: 90,
			offPeakDiscountEnabled: false,
			enabled: true,
			apiKeys: [
				{
					id: "key-2",
					providerId: "prov-2",
					label: "Claude Key",
					keyPreview: "sk-ant…wxyz",
					enabled: true,
					insertedAt: "2026-11-21T00:00:00Z",
				},
			],
			models: [
				{
					id: "model-ant-1",
					providerId: "prov-2",
					modelId: "claude-sonnet-4",
					upstreamModelId: "claude-sonnet-4",
					displayName: "Claude Sonnet 4",
					enabled: true,
					contextWindow: 200_000,
					maxOutputTokens: 16_384,
					supportsThinking: true,
					supportsTools: true,
					supportsImages: true,
					reasoningEfforts: ["low", "high"],
					cacheHitPriceMc: "300000",
					cacheMissPriceMc: "3000000",
					outputPriceMc: "15000000",
					markupRatio: 1.5,
					insertedAt: "2026-11-21T00:00:00Z",
				},
			],
			insertedAt: "2026-11-21T00:00:00Z",
			updatedAt: "2026-11-21T00:00:00Z",
		},
	];
}

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(() => {
	cleanup();
});

describe("ProviderManager background refresh", () => {
	it("切换 API Key 与删除已保存模型触发刷新时保留当前及跨 Provider 的未保存模型草稿", async () => {
		let providersState: AdminLlmProvider[] = makeProvidersFixture();

		queryMock.mockImplementation(async ({ query }: { query: unknown }) => {
			if (query === ADMIN_LLM_PROVIDERS) {
				return { data: { adminLlmProviders: providersState } };
			}
			if (query === ADMIN_LLM_PRICING_PRESETS) {
				return { data: { adminLlmPricingPresets: SAMPLE_PRESETS } };
			}
			return { data: {} };
		});

		mutateMock.mockImplementation(
			async ({
				mutation,
				variables,
			}: {
				mutation: unknown;
				variables?: Record<string, unknown>;
			}) => {
				if (mutation === ADMIN_UPDATE_LLM_PROVIDER_API_KEY) {
					const enabled = Boolean(variables?.enabled);
					providersState = providersState.map((provider) =>
						provider.id === "prov-1"
							? {
									...provider,
									apiKeys: provider.apiKeys.map((key) =>
										key.id === "key-1" ? { ...key, enabled } : key,
									),
								}
							: provider,
					);
					return {
						data: {
							adminUpdateLlmProviderApiKey: {
								...providersState[0].apiKeys[0],
								enabled,
							},
						},
					};
				}
				if (mutation === ADMIN_DELETE_LLM_PROVIDER_MODEL) {
					providersState = providersState.map((provider) =>
						provider.id === "prov-1"
							? {
									...provider,
									models: provider.models.filter(
										(model) => model.id !== "model-ds-1",
									),
								}
							: provider,
					);
					return { data: { adminDeleteLlmProviderModel: true } };
				}
				return { data: {} };
			},
		);

		render(<ProviderManager />);

		const deepseekCard = await screen.findByTestId("provider-card-deepseek");
		const anthropicCard = await screen.findByTestId("provider-card-anthropic");

		// 在 deepseek 中手动添加一个尚未保存的模型草稿
		fireEvent.change(within(deepseekCard).getByLabelText("对外模型 ID"), {
			target: { value: "custom-unsaved" },
		});
		fireEvent.change(within(deepseekCard).getByLabelText("展示名称（可选）"), {
			target: { value: "Unsaved Draft" },
		});
		fireEvent.click(
			within(deepseekCard).getByRole("button", { name: "手动添加模型" }),
		);
		expect(
			await within(deepseekCard).findByTestId("provider-model-row-custom-unsaved"),
		).toBeInTheDocument();

		// 在 anthropic 中修改已保存模型的展示名称草稿
		const anthropicRow = within(anthropicCard).getByTestId(
			"provider-model-row-claude-sonnet-4",
		);
		fireEvent.change(within(anthropicRow).getByLabelText("展示名称"), {
			target: { value: "Claude Sonnet Edited" },
		});

		// 停用 deepseek 的 API Key，触发 onChanged() -> loadAll() 后台刷新
		fireEvent.click(within(deepseekCard).getByRole("button", { name: "停用" }));
		await waitFor(() => {
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: ADMIN_UPDATE_LLM_PROVIDER_API_KEY,
				variables: { id: "key-1", enabled: false },
			});
		});
		expect(
			await within(deepseekCard).findByRole("button", { name: "启用" }),
		).toBeInTheDocument();

		const unsavedAfterKeyToggle = within(deepseekCard).getByTestId(
			"provider-model-row-custom-unsaved",
		);
		expect(
			within(unsavedAfterKeyToggle).getByLabelText("展示名称"),
		).toHaveValue("Unsaved Draft");
		const anthropicAfterKeyToggle = within(anthropicCard).getByTestId(
			"provider-model-row-claude-sonnet-4",
		);
		expect(
			within(anthropicAfterKeyToggle).getByLabelText("展示名称"),
		).toHaveValue("Claude Sonnet Edited");

		// 删除 deepseek 已保存的模型，再次触发 onChanged() -> loadAll()
		const savedDeepseekRow = within(deepseekCard).getByTestId(
			"provider-model-row-deepseek-chat",
		);
		fireEvent.click(
			within(savedDeepseekRow).getByRole("button", { name: "删除" }),
		);
		await waitFor(() => {
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: ADMIN_DELETE_LLM_PROVIDER_MODEL,
				variables: { id: "model-ds-1" },
			});
		});
		await waitFor(() => {
			expect(
				within(deepseekCard).queryByTestId("provider-model-row-deepseek-chat"),
			).not.toBeInTheDocument();
		});

		const unsavedAfterDelete = within(deepseekCard).getByTestId(
			"provider-model-row-custom-unsaved",
		);
		expect(within(unsavedAfterDelete).getByLabelText("展示名称")).toHaveValue(
			"Unsaved Draft",
		);
		const anthropicAfterDelete = within(anthropicCard).getByTestId(
			"provider-model-row-claude-sonnet-4",
		);
		expect(
			within(anthropicAfterDelete).getByLabelText("展示名称"),
		).toHaveValue("Claude Sonnet Edited");
	});

	it("后台刷新失败时显示错误提示并保留已有 Provider 卡片与未保存草稿", async () => {
		const [deepseekProvider] = makeProvidersFixture();
		let failNextProvidersQuery = false;

		queryMock.mockImplementation(async ({ query }: { query: unknown }) => {
			if (query === ADMIN_LLM_PROVIDERS) {
				if (failNextProvidersQuery) {
					throw new Error("refresh failed");
				}
				return { data: { adminLlmProviders: [deepseekProvider] } };
			}
			if (query === ADMIN_LLM_PRICING_PRESETS) {
				return { data: { adminLlmPricingPresets: SAMPLE_PRESETS } };
			}
			return { data: {} };
		});

		mutateMock.mockImplementation(async ({ mutation }: { mutation: unknown }) => {
			if (mutation === ADMIN_UPDATE_LLM_PROVIDER_API_KEY) {
				return {
					data: {
						adminUpdateLlmProviderApiKey: {
							...deepseekProvider.apiKeys[0],
							enabled: false,
						},
					},
				};
			}
			return { data: {} };
		});

		render(<ProviderManager />);
		const deepseekCard = await screen.findByTestId("provider-card-deepseek");

		fireEvent.change(within(deepseekCard).getByLabelText("对外模型 ID"), {
			target: { value: "draft-kept" },
		});
		fireEvent.click(
			within(deepseekCard).getByRole("button", { name: "手动添加模型" }),
		);
		expect(
			await within(deepseekCard).findByTestId("provider-model-row-draft-kept"),
		).toBeInTheDocument();

		failNextProvidersQuery = true;
		fireEvent.click(within(deepseekCard).getByRole("button", { name: "停用" }));

		const errorBanner = await screen.findByTestId("provider-load-error");
		expect(errorBanner).toHaveTextContent("refresh failed");
		expect(screen.getByTestId("provider-card-deepseek")).toBeInTheDocument();
		expect(
			within(screen.getByTestId("provider-card-deepseek")).getByTestId(
				"provider-model-row-draft-kept",
			),
		).toBeInTheDocument();
	});

	it("并发异步删除多行模型时按稳定 ID 移除行而不误删后续行草稿", async () => {
		const [baseProvider] = makeProvidersFixture();
		const baseModel = baseProvider.models[0];
		let currentModels = [
			{ ...baseModel, id: "m-a", modelId: "model-a", upstreamModelId: "model-a", displayName: "Model A" },
			{ ...baseModel, id: "m-b", modelId: "model-b", upstreamModelId: "model-b", displayName: "Model B" },
			{ ...baseModel, id: "m-c", modelId: "model-c", upstreamModelId: "model-c", displayName: "Model C" },
		];

		queryMock.mockImplementation(async ({ query }: { query: unknown }) => {
			if (query === ADMIN_LLM_PROVIDERS) {
				return { data: { adminLlmProviders: [{ ...baseProvider, models: currentModels }] } };
			}
			if (query === ADMIN_LLM_PRICING_PRESETS) {
				return { data: { adminLlmPricingPresets: SAMPLE_PRESETS } };
			}
			return { data: {} };
		});

		const pendingDeletes = new Map<string, () => void>();
		mutateMock.mockImplementation(
			({ mutation, variables }: { mutation: unknown; variables?: Record<string, unknown> }) => {
				if (mutation === ADMIN_DELETE_LLM_PROVIDER_MODEL) {
					const id = String(variables?.id ?? "");
					return new Promise((resolve) => {
						pendingDeletes.set(id, () => {
							currentModels = currentModels.filter((item) => item.id !== id);
							resolve({ data: { adminDeleteLlmProviderModel: true } });
						});
					});
				}
				return Promise.resolve({ data: {} });
			},
		);

		render(<ProviderManager />);
		const card = await screen.findByTestId("provider-card-deepseek");

		const rowA = within(card).getByTestId("provider-model-row-model-a");
		const rowB = within(card).getByTestId("provider-model-row-model-b");
		const rowC = within(card).getByTestId("provider-model-row-model-c");

		fireEvent.change(within(rowC).getByLabelText("展示名称"), {
			target: { value: "Model C Edited" },
		});

		const deleteBtnA = within(rowA).getByRole("button", { name: "删除" });
		const deleteBtnB = within(rowB).getByRole("button", { name: "删除" });
		fireEvent.click(deleteBtnA);
		fireEvent.click(deleteBtnB);

		expect(deleteBtnA).toBeDisabled();
		expect(deleteBtnB).toBeDisabled();
		expect(within(card).getByRole("button", { name: "保存全部模型" })).toBeDisabled();

		pendingDeletes.get("m-a")?.();
		await waitFor(() => {
			expect(within(card).queryByTestId("provider-model-row-model-a")).not.toBeInTheDocument();
		});
		expect(within(card).getByTestId("provider-model-row-model-b")).toBeInTheDocument();
		expect(within(within(card).getByTestId("provider-model-row-model-b")).getByRole("button", { name: "删除" })).toBeDisabled();
		expect(within(within(card).getByTestId("provider-model-row-model-c")).getByLabelText("展示名称")).toHaveValue("Model C Edited");

		pendingDeletes.get("m-b")?.();
		await waitFor(() => {
			expect(within(card).queryByTestId("provider-model-row-model-b")).not.toBeInTheDocument();
		});
		const remainingC = within(card).getByTestId("provider-model-row-model-c");
		expect(remainingC).toBeInTheDocument();
		expect(within(remainingC).getByLabelText("展示名称")).toHaveValue("Model C Edited");
		expect(within(card).getByRole("button", { name: "保存全部模型" })).not.toBeDisabled();
	});
});
