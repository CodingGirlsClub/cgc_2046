import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import { ADMIN_LLM_USAGE_ANALYTICS } from "@/lib/graphql/llm-gateway";
import {
	ADMIN_ADD_LLM_PROVIDER_API_KEY,
	ADMIN_CREATE_LLM_PROVIDER,
	ADMIN_FETCH_LLM_PROVIDER_UPSTREAM_MODELS,
	ADMIN_LLM_PRICING_PRESETS,
	ADMIN_LLM_PROVIDERS,
	ADMIN_SAVE_LLM_PROVIDER_MODELS,
	ADMIN_UPDATE_LLM_PROVIDER_API_KEY,
	type AdminLlmProvider,
	type LlmModelPricingPreset,
	type LlmUpstreamDiscoveredModel,
} from "@/lib/graphql/llm-providers";
import AdminLlmPage from "./page";
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

const BASE_PROVIDER: AdminLlmProvider = {
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
	models: [],
	insertedAt: "2026-11-21T00:00:00Z",
	updatedAt: "2026-11-21T00:00:00Z",
};

const DISCOVERED_MODELS: LlmUpstreamDiscoveredModel[] = [
	{
		modelId: "deepseek-chat",
		upstreamModelId: "deepseek-chat",
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
		presetMatched: true,
	},
	{
		modelId: "deepseek-reasoner",
		upstreamModelId: "deepseek-reasoner",
		displayName: "DeepSeek Reasoner",
		contextWindow: 128_000,
		maxOutputTokens: 32_768,
		supportsThinking: true,
		supportsTools: true,
		supportsImages: false,
		reasoningEfforts: ["low", "high"],
		cacheHitPriceMc: "200000",
		cacheMissPriceMc: "2000000",
		outputPriceMc: "3000000",
		markupRatio: 1.5,
		presetMatched: true,
	},
];

function mockProviderQueries(providers: AdminLlmProvider[]) {
	queryMock.mockImplementation(async ({ query }: { query: unknown }) => {
		if (query === ADMIN_LLM_USAGE_ANALYTICS) {
			return { data: { adminLlmUsageAnalytics: [] } };
		}
		if (query === ADMIN_LLM_PROVIDERS) {
			return { data: { adminLlmProviders: providers } };
		}
		if (query === ADMIN_LLM_PRICING_PRESETS) {
			return { data: { adminLlmPricingPresets: SAMPLE_PRESETS } };
		}
		return { data: {} };
	});
}

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(() => {
	cleanup();
});

describe("/admin/llm Provider 与模型目录管理", () => {
	it("支持从用量统计 Tab 切换到 Provider 与模型目录 Tab", async () => {
		mockProviderQueries([BASE_PROVIDER]);

		render(<AdminLlmPage />);

		expect(await screen.findByTestId("admin-llm-empty")).toBeInTheDocument();

		fireEvent.click(screen.getByRole("tab", { name: "Provider 与模型目录" }));

		expect(
			await screen.findByTestId("admin-llm-provider-manager"),
		).toBeInTheDocument();
		expect(
			await screen.findByTestId("provider-card-deepseek"),
		).toBeInTheDocument();
		expect(queryMock).toHaveBeenCalledWith(
			expect.objectContaining({ query: ADMIN_LLM_PROVIDERS }),
		);
		expect(queryMock).toHaveBeenCalledWith(
			expect.objectContaining({ query: ADMIN_LLM_PRICING_PRESETS }),
		);
	});

	it("加载态、错误重试与空状态正常工作", async () => {
		queryMock.mockReturnValue(new Promise(() => {}));
		render(<ProviderManager />);
		expect(screen.getByTestId("provider-loading")).toBeInTheDocument();

		cleanup();
		let failedOnce = false;
		queryMock.mockImplementation(async ({ query }: { query: unknown }) => {
			if (!failedOnce) {
				failedOnce = true;
				throw new Error("graph boom");
			}
			if (query === ADMIN_LLM_PROVIDERS) {
				return { data: { adminLlmProviders: [] } };
			}
			return { data: { adminLlmPricingPresets: SAMPLE_PRESETS } };
		});

		render(<ProviderManager />);
		const errorBox = await screen.findByTestId("provider-load-error");
		expect(errorBox).toHaveTextContent("graph boom");

		failedOnce = true;
		queryMock.mockImplementation(async ({ query }: { query: unknown }) => {
			if (query === ADMIN_LLM_PROVIDERS) {
				return { data: { adminLlmProviders: [] } };
			}
			return { data: { adminLlmPricingPresets: SAMPLE_PRESETS } };
		});

		fireEvent.click(within(errorBox).getByRole("button", { name: "重试" }));
		expect(await screen.findByTestId("provider-empty")).toBeInTheDocument();
	});

	it("使用预设模板创建 Provider 并重新加载列表", async () => {
		let providersList: AdminLlmProvider[] = [];
		queryMock.mockImplementation(async ({ query }: { query: unknown }) => {
			if (query === ADMIN_LLM_PROVIDERS) {
				return { data: { adminLlmProviders: providersList } };
			}
			return { data: { adminLlmPricingPresets: SAMPLE_PRESETS } };
		});
		mutateMock.mockImplementation(async ({ mutation }: { mutation: unknown }) => {
			if (mutation === ADMIN_CREATE_LLM_PROVIDER) {
				providersList = [BASE_PROVIDER];
				return { data: { adminCreateLlmProvider: BASE_PROVIDER } };
			}
			return { data: {} };
		});

		render(<ProviderManager />);
		expect(await screen.findByTestId("provider-empty")).toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "新增 Provider" }));
		const form = await screen.findByTestId("provider-form");

		fireEvent.click(within(form).getByRole("button", { name: "DeepSeek" }));
		fireEvent.click(within(form).getByRole("button", { name: "保存 Provider" }));

		await waitFor(() => {
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: ADMIN_CREATE_LLM_PROVIDER,
				variables: {
					input: {
						name: "DeepSeek",
						slug: "deepseek",
						protocol: "openai_compatible",
						baseUrl: "https://api.deepseek.com",
						chatPath: null,
						modelsPath: null,
						priority: 100,
						offPeakDiscountEnabled: true,
						enabled: true,
					},
				},
			});
		});

		expect(
			await screen.findByTestId("provider-card-deepseek"),
		).toBeInTheDocument();
	});

	it("添加与切换 API Key：提交后清空明文输入框且 DOM 仅显示 keyPreview", async () => {
		const secretPlaintext = "sk-live-super-secret-value-9988";
		const newKey = {
			id: "key-2",
			providerId: "prov-1",
			label: "备用 Key",
			keyPreview: "sk-live…9988",
			enabled: true,
			insertedAt: "2026-11-21T01:00:00Z",
		};
		let currentProvider: AdminLlmProvider = {
			...BASE_PROVIDER,
			apiKeys: [],
		};

		queryMock.mockImplementation(async ({ query }: { query: unknown }) => {
			if (query === ADMIN_LLM_PROVIDERS) {
				return { data: { adminLlmProviders: [currentProvider] } };
			}
			return { data: { adminLlmPricingPresets: SAMPLE_PRESETS } };
		});
		mutateMock.mockImplementation(async ({ mutation }: { mutation: unknown }) => {
			if (mutation === ADMIN_ADD_LLM_PROVIDER_API_KEY) {
				currentProvider = {
					...currentProvider,
					apiKeys: [newKey],
				};
				return { data: { adminAddLlmProviderApiKey: newKey } };
			}
			if (mutation === ADMIN_UPDATE_LLM_PROVIDER_API_KEY) {
				currentProvider = {
					...currentProvider,
					apiKeys: [{ ...newKey, enabled: false }],
				};
				return {
					data: {
						adminUpdateLlmProviderApiKey: { ...newKey, enabled: false },
					},
				};
			}
			return { data: {} };
		});

		render(<ProviderManager />);
		const card = await screen.findByTestId("provider-card-deepseek");
		const keyForm = within(card).getByTestId("provider-add-key-form-deepseek");

		const labelInput = within(keyForm).getByLabelText("Key 标签") as HTMLInputElement;
		const secretInput = within(keyForm).getByLabelText("API Key 密钥") as HTMLInputElement;

		fireEvent.change(labelInput, { target: { value: "备用 Key" } });
		fireEvent.change(secretInput, { target: { value: secretPlaintext } });
		fireEvent.submit(keyForm);

		await waitFor(() => {
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: ADMIN_ADD_LLM_PROVIDER_API_KEY,
				variables: {
					providerId: "prov-1",
					label: "备用 Key",
					apiKey: secretPlaintext,
				},
			});
		});

		expect(await within(card).findByText("sk-live…9988")).toBeInTheDocument();
		expect(secretInput.value).toBe("");
		expect(labelInput.value).toBe("");
		expect(card.textContent).not.toContain(secretPlaintext);

		fireEvent.click(within(card).getByRole("button", { name: "停用" }));
		await waitFor(() => {
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: ADMIN_UPDATE_LLM_PROVIDER_API_KEY,
				variables: { id: "key-2", enabled: false },
			});
		});
	});

	it("从上游拉取模型、筛选加入、手动添加并编辑保存模型配置", async () => {
		let currentProvider: AdminLlmProvider = {
			...BASE_PROVIDER,
			models: [],
		};

		queryMock.mockImplementation(async ({ query }: { query: unknown }) => {
			if (query === ADMIN_LLM_PROVIDERS) {
				return { data: { adminLlmProviders: [currentProvider] } };
			}
			return { data: { adminLlmPricingPresets: SAMPLE_PRESETS } };
		});
		mutateMock.mockImplementation(
			async ({
				mutation,
				variables,
			}: {
				mutation: unknown;
				variables: Record<string, unknown>;
			}) => {
				if (mutation === ADMIN_FETCH_LLM_PROVIDER_UPSTREAM_MODELS) {
					return {
						data: { adminFetchLlmProviderUpstreamModels: DISCOVERED_MODELS },
					};
				}
				if (mutation === ADMIN_SAVE_LLM_PROVIDER_MODELS) {
					const models = (variables.models as AdminLlmProvider["models"]) ?? [];
					currentProvider = {
						...currentProvider,
						models: models.map((m, idx) => ({
							...m,
							id: `model-${idx + 1}`,
							providerId: "prov-1",
							insertedAt: "2026-11-21T02:00:00Z",
						})),
					};
					return {
						data: { adminSaveLlmProviderModels: currentProvider.models },
					};
				}
				return { data: {} };
			},
		);

		render(<ProviderManager />);
		const card = await screen.findByTestId("provider-card-deepseek");

		fireEvent.click(
			within(card).getByRole("button", { name: "从上游拉取模型" }),
		);

		const discoveredPanel = await within(card).findByTestId(
			"discovered-models-deepseek",
		);
		expect(
			within(discoveredPanel).getByText("deepseek-chat"),
		).toBeInTheDocument();
		expect(
			within(discoveredPanel).getByText("deepseek-reasoner"),
		).toBeInTheDocument();

		const searchInput = within(discoveredPanel).getByPlaceholderText(
			"搜索上游返回的模型 ID…",
		);
		fireEvent.change(searchInput, { target: { value: "reasoner" } });
		expect(
			within(discoveredPanel).queryByText("deepseek-chat"),
		).not.toBeInTheDocument();

		fireEvent.change(searchInput, { target: { value: "" } });
		// 仅保留 deepseek-chat，取消 deepseek-reasoner
		const reasonerCheckbox = within(discoveredPanel)
			.getByText("deepseek-reasoner")
			.closest("label")
			?.querySelector("input[type='checkbox']") as HTMLInputElement;
		fireEvent.click(reasonerCheckbox);

		fireEvent.click(
			within(discoveredPanel).getByRole("button", {
				name: "添加所选模型（1）",
			}),
		);

		const chatRow = await within(card).findByTestId(
			"provider-model-row-deepseek-chat",
		);
		expect(
			within(chatRow).getByLabelText(/输入成本（元 \/ 1M）/),
		).toHaveValue("2");
		expect(within(chatRow).getByText("折合用户售价：¥3.00")).toBeInTheDocument();

		// 编辑展示名称
		fireEvent.change(within(chatRow).getByLabelText("展示名称"), {
			target: { value: "DeepSeek Chat 官方版" },
		});

		// 手动添加一个自定义模型
		fireEvent.change(within(card).getByLabelText("对外模型 ID"), {
			target: { value: "custom-coder" },
		});
		fireEvent.change(within(card).getByLabelText("展示名称（可选）"), {
			target: { value: "Custom Coder" },
		});
		fireEvent.click(within(card).getByRole("button", { name: "手动添加模型" }));

		expect(
			await within(card).findByTestId("provider-model-row-custom-coder"),
		).toBeInTheDocument();

		fireEvent.click(within(card).getByRole("button", { name: "保存全部模型" }));

		await waitFor(() => {
			expect(mutateMock).toHaveBeenCalledWith({
				mutation: ADMIN_SAVE_LLM_PROVIDER_MODELS,
				variables: {
					providerId: "prov-1",
					models: expect.arrayContaining([
						expect.objectContaining({
							modelId: "deepseek-chat",
							displayName: "DeepSeek Chat 官方版",
							cacheHitPriceMc: "200000",
							cacheMissPriceMc: "2000000",
							outputPriceMc: "3000000",
							markupRatio: 1.5,
						}),
						expect.objectContaining({
							modelId: "custom-coder",
							displayName: "Custom Coder",
						}),
					]),
				},
			});
		});
	});
});
