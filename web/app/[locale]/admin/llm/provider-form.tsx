"use client";

import { type FormEvent } from "react";
import { useTranslations } from "next-intl";
import type { LlmProviderProtocol } from "@/lib/graphql/llm-providers";

export interface ProviderFormState {
	editingId: string | null;
	name: string;
	slug: string;
	protocol: LlmProviderProtocol;
	baseUrl: string;
	chatPath: string;
	modelsPath: string;
	priority: string;
	offPeakDiscountEnabled: boolean;
	enabled: boolean;
}

export const EMPTY_PROVIDER_FORM: ProviderFormState = {
	editingId: null,
	name: "",
	slug: "",
	protocol: "openai_compatible",
	baseUrl: "",
	chatPath: "",
	modelsPath: "",
	priority: "100",
	offPeakDiscountEnabled: false,
	enabled: true,
};

interface ProviderTemplate {
	id: string;
	labelKey?: "templateVolcengine";
	label?: string;
	nameKey?: "templateVolcengine";
	name?: string;
	slug: string;
	protocol: LlmProviderProtocol;
	baseUrl: string;
	offPeak: boolean;
}

const PROVIDER_TEMPLATES: ProviderTemplate[] = [
	{
		id: "deepseek",
		label: "DeepSeek",
		name: "DeepSeek",
		slug: "deepseek",
		protocol: "openai_compatible",
		baseUrl: "https://api.deepseek.com",
		offPeak: true,
	},
	{
		id: "anthropic",
		label: "Anthropic",
		name: "Anthropic",
		slug: "anthropic",
		protocol: "anthropic",
		baseUrl: "https://api.anthropic.com",
		offPeak: false,
	},
	{
		id: "volcengine",
		labelKey: "templateVolcengine",
		nameKey: "templateVolcengine",
		slug: "volcengine",
		protocol: "openai_compatible",
		baseUrl: "https://ark.cn-beijing.volces.com/api/v3",
		offPeak: false,
	},
	{
		id: "moonshot",
		label: "Moonshot",
		name: "Moonshot",
		slug: "moonshot",
		protocol: "openai_compatible",
		baseUrl: "https://api.moonshot.cn/v1",
		offPeak: false,
	},
	{
		id: "minimax",
		label: "MiniMax",
		name: "MiniMax",
		slug: "minimax",
		protocol: "openai_compatible",
		baseUrl: "https://api.minimax.io/v1",
		offPeak: false,
	},
	{
		id: "openai",
		label: "OpenAI",
		name: "OpenAI",
		slug: "openai",
		protocol: "openai_compatible",
		baseUrl: "https://api.openai.com/v1",
		offPeak: false,
	},
];

interface ProviderFormProps {
	form: ProviderFormState;
	submitting: boolean;
	error: string | null;
	onChange: (updater: (prev: ProviderFormState) => ProviderFormState) => void;
	onSubmit: (event: FormEvent) => void;
	onCancel: () => void;
}

export default function ProviderForm({
	form,
	submitting,
	error,
	onChange,
	onSubmit,
	onCancel,
}: ProviderFormProps) {
	const t = useTranslations("adminLlm");

	return (
		<form
			onSubmit={onSubmit}
			className="admin-card admin-card__body grid gap-4"
			data-testid="provider-form"
		>
			<div className="flex flex-wrap items-center justify-between gap-2">
				<h3 className="text-sm font-medium text-ink">
					{form.editingId ? t("editProviderTitle") : t("createProviderTitle")}
				</h3>
				{!form.editingId && (
					<div className="flex flex-wrap items-center gap-1.5">
						<span className="text-xs text-ink-3">{t("templatesLabel")}</span>
						{PROVIDER_TEMPLATES.map((tpl) => {
							const label = tpl.labelKey ? t(tpl.labelKey) : (tpl.label ?? "");
							const name = tpl.nameKey ? t(tpl.nameKey) : (tpl.name ?? "");
							return (
								<button
									key={tpl.id}
									type="button"
									onClick={() =>
										onChange((prev) => ({
											...prev,
											name,
											slug: tpl.slug,
											protocol: tpl.protocol,
											baseUrl: tpl.baseUrl,
											offPeakDiscountEnabled: tpl.offPeak,
										}))
									}
									className="l-btn-outline text-xs"
								>
									{label}
								</button>
							);
						})}
					</div>
				)}
			</div>

			<div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("providerNameLabel")}</span>
					<input
						type="text"
						value={form.name}
						onChange={(e) => onChange((p) => ({ ...p, name: e.target.value }))}
						placeholder="DeepSeek"
						className="l-input"
					/>
				</label>
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("providerSlugLabel")}</span>
					<input
						type="text"
						value={form.slug}
						onChange={(e) => onChange((p) => ({ ...p, slug: e.target.value }))}
						placeholder="deepseek"
						className="l-input font-mono"
					/>
				</label>
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("providerProtocolLabel")}</span>
					<select
						value={form.protocol}
						onChange={(e) =>
							onChange((p) => ({
								...p,
								protocol:
									e.target.value === "anthropic"
										? "anthropic"
										: "openai_compatible",
							}))
						}
						className="l-input"
					>
						<option value="openai_compatible">{t("protocolOpenai")}</option>
						<option value="anthropic">{t("protocolAnthropic")}</option>
					</select>
				</label>
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("providerPriorityLabel")}</span>
					<input
						type="number"
						min={0}
						value={form.priority}
						onChange={(e) =>
							onChange((p) => ({ ...p, priority: e.target.value }))
						}
						className="l-input"
					/>
				</label>
			</div>

			<div className="grid gap-3 sm:grid-cols-3">
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("providerBaseUrlLabel")}</span>
					<input
						type="text"
						value={form.baseUrl}
						onChange={(e) =>
							onChange((p) => ({ ...p, baseUrl: e.target.value }))
						}
						placeholder="https://api.deepseek.com"
						className="l-input font-mono"
					/>
				</label>
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("providerChatPathLabel")}</span>
					<input
						type="text"
						value={form.chatPath}
						onChange={(e) =>
							onChange((p) => ({ ...p, chatPath: e.target.value }))
						}
						placeholder="/chat/completions"
						className="l-input font-mono"
					/>
				</label>
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("providerModelsPathLabel")}</span>
					<input
						type="text"
						value={form.modelsPath}
						onChange={(e) =>
							onChange((p) => ({ ...p, modelsPath: e.target.value }))
						}
						placeholder="/models"
						className="l-input font-mono"
					/>
				</label>
			</div>

			<div className="flex flex-wrap items-center gap-6 text-xs text-ink-2">
				<label className="flex items-center gap-2">
					<input
						type="checkbox"
						checked={form.enabled}
						onChange={(e) =>
							onChange((p) => ({ ...p, enabled: e.target.checked }))
						}
					/>
					<span>{t("providerEnabledLabel")}</span>
				</label>
				<label className="flex items-center gap-2">
					<input
						type="checkbox"
						checked={form.offPeakDiscountEnabled}
						onChange={(e) =>
							onChange((p) => ({
								...p,
								offPeakDiscountEnabled: e.target.checked,
							}))
						}
					/>
					<span>{t("providerOffPeakLabel")}</span>
				</label>
			</div>

			{error && (
				<p role="alert" className="text-xs text-red-400">
					{error}
				</p>
			)}

			<div className="flex items-center gap-2">
				<button type="submit" disabled={submitting} className="l-btn-primary">
					{submitting ? t("submitting") : t("saveProviderSubmit")}
				</button>
				<button type="button" onClick={onCancel} className="l-btn-outline">
					{t("cancelAction")}
				</button>
			</div>
		</form>
	);
}
