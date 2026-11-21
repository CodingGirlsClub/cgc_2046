"use client";

import { type FormEvent, useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import {
	ADMIN_CREATE_LLM_PROVIDER,
	ADMIN_DELETE_LLM_PROVIDER,
	ADMIN_LLM_PRICING_PRESETS,
	ADMIN_LLM_PROVIDERS,
	ADMIN_UPDATE_LLM_PROVIDER,
	type AdminLlmProvider,
	type AdminLlmProviderInput,
	type LlmModelPricingPreset,
} from "@/lib/graphql/llm-providers";
import ProviderForm, {
	EMPTY_PROVIDER_FORM,
	type ProviderFormState,
} from "./provider-form";
import ProviderKeysSection from "./provider-keys-section";
import ProviderModelsSection from "./provider-models-section";

function errorMessage(err: unknown, fallback: string): string {
	return err instanceof Error && err.message ? err.message : fallback;
}

export default function ProviderManager() {
	const t = useTranslations("adminLlm");
	const [providers, setProviders] = useState<AdminLlmProvider[] | null>(null);
	const [presets, setPresets] = useState<LlmModelPricingPreset[]>([]);
	const [loading, setLoading] = useState(true);
	const [loadError, setLoadError] = useState<string | null>(null);

	const [formOpen, setFormOpen] = useState(false);
	const [form, setForm] = useState<ProviderFormState>(EMPTY_PROVIDER_FORM);
	const [submitting, setSubmitting] = useState(false);
	const [formError, setFormError] = useState<string | null>(null);
	const [formStatus, setFormStatus] = useState<string | null>(null);
	const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);
	const [busyProviderId, setBusyProviderId] = useState<string | null>(null);

	const loadAll = useCallback(async () => {
		setLoading(true);
		setLoadError(null);
		try {
			const [providersRes, presetsRes] = await Promise.all([
				client.query({ query: ADMIN_LLM_PROVIDERS, fetchPolicy: "network-only" }),
				client.query({
					query: ADMIN_LLM_PRICING_PRESETS,
					fetchPolicy: "cache-first",
				}),
			]);
			setProviders(providersRes.data?.adminLlmProviders ?? []);
			setPresets(presetsRes.data?.adminLlmPricingPresets ?? []);
		} catch (err) {
			setLoadError(errorMessage(err, t("providersLoadFailed")));
			setProviders(null);
		} finally {
			setLoading(false);
		}
	}, [t]);

	useEffect(() => {
		let cancelled = false;
		Promise.all([
			client.query({ query: ADMIN_LLM_PROVIDERS, fetchPolicy: "network-only" }),
			client.query({
				query: ADMIN_LLM_PRICING_PRESETS,
				fetchPolicy: "cache-first",
			}),
		])
			.then(([providersRes, presetsRes]) => {
				if (cancelled) return;
				setProviders(providersRes.data?.adminLlmProviders ?? []);
				setPresets(presetsRes.data?.adminLlmPricingPresets ?? []);
				setLoadError(null);
			})
			.catch((err) => {
				if (cancelled) return;
				setLoadError(errorMessage(err, t("providersLoadFailed")));
				setProviders(null);
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [t]);

	function openCreateForm() {
		setForm(EMPTY_PROVIDER_FORM);
		setFormError(null);
		setFormStatus(null);
		setFormOpen(true);
	}

	function openEditForm(provider: AdminLlmProvider) {
		setForm({
			editingId: provider.id,
			name: provider.name,
			slug: provider.slug,
			protocol:
				provider.protocol === "anthropic" ? "anthropic" : "openai_compatible",
			baseUrl: provider.baseUrl,
			chatPath: provider.chatPath ?? "",
			modelsPath: provider.modelsPath ?? "",
			priority: String(provider.priority),
			offPeakDiscountEnabled: provider.offPeakDiscountEnabled,
			enabled: provider.enabled,
		});
		setFormError(null);
		setFormStatus(null);
		setFormOpen(true);
	}

	async function handleSubmitProvider(event: FormEvent) {
		event.preventDefault();
		setFormError(null);
		setFormStatus(null);

		const name = form.name.trim();
		const slug = form.slug.trim().toLowerCase();
		const baseUrl = form.baseUrl.trim();
		const priority = Number(form.priority);

		if (!name) {
			setFormError(t("validationProviderName"));
			return;
		}
		if (!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(slug)) {
			setFormError(t("validationProviderSlug"));
			return;
		}
		if (!baseUrl.startsWith("https://") && !baseUrl.startsWith("http://")) {
			setFormError(t("validationProviderUrl"));
			return;
		}
		if (!Number.isInteger(priority) || priority < 0) {
			setFormError(t("validationProviderPriority"));
			return;
		}

		const input: AdminLlmProviderInput = {
			name,
			slug,
			protocol: form.protocol,
			baseUrl,
			chatPath: form.chatPath.trim() || null,
			modelsPath: form.modelsPath.trim() || null,
			priority,
			offPeakDiscountEnabled: form.offPeakDiscountEnabled,
			enabled: form.enabled,
		};

		setSubmitting(true);
		try {
			if (form.editingId) {
				await client.mutate({
					mutation: ADMIN_UPDATE_LLM_PROVIDER,
					variables: { id: form.editingId, input },
				});
				setFormStatus(t("providerUpdateSuccess", { name }));
			} else {
				await client.mutate({
					mutation: ADMIN_CREATE_LLM_PROVIDER,
					variables: { input },
				});
				setFormStatus(t("providerCreateSuccess", { name }));
			}
			setFormOpen(false);
			await loadAll();
		} catch (err) {
			setFormError(errorMessage(err, t("providerSaveFailed")));
		} finally {
			setSubmitting(false);
		}
	}

	async function handleDeleteProvider(id: string) {
		setBusyProviderId(id);
		try {
			await client.mutate({
				mutation: ADMIN_DELETE_LLM_PROVIDER,
				variables: { id },
			});
			setConfirmDeleteId(null);
			await loadAll();
		} catch (err) {
			setLoadError(errorMessage(err, t("providerDeleteFailed")));
		} finally {
			setBusyProviderId(null);
		}
	}

	return (
		<div className="grid gap-6" data-testid="admin-llm-provider-manager">
			<div className="flex flex-wrap items-center justify-between gap-3">
				<div>
					<h2 className="admin-section-title m-0">{t("providersTitle")}</h2>
					<p className="mt-1 text-xs text-ink-3">{t("providersSubtitle")}</p>
				</div>
				<div className="flex items-center gap-2">
					<button
						type="button"
						onClick={() => void loadAll()}
						disabled={loading}
						className="l-btn-outline"
					>
						{t("refresh")}
					</button>
					<button type="button" onClick={openCreateForm} className="l-btn-primary">
						{t("addProvider")}
					</button>
				</div>
			</div>

			{formStatus && (
				<p role="status" className="text-xs text-emerald-400">
					{formStatus}
				</p>
			)}

			{formOpen && (
				<ProviderForm
					form={form}
					submitting={submitting}
					error={formError}
					onChange={setForm}
					onSubmit={(e) => void handleSubmitProvider(e)}
					onCancel={() => setFormOpen(false)}
				/>
			)}

			{loadError && (
				<div
					className="admin-card admin-card__body flex flex-wrap items-center justify-between gap-3"
					role="alert"
					data-testid="provider-load-error"
				>
					<p className="text-sm text-red-400">{loadError}</p>
					<button
						type="button"
						onClick={() => void loadAll()}
						className="l-btn-outline"
					>
						{t("retry")}
					</button>
				</div>
			)}

			{loading && !loadError && (
				<div className="admin-card admin-empty" data-testid="provider-loading">
					{t("providersLoading")}
				</div>
			)}

			{!loading && !loadError && providers && providers.length === 0 && (
				<div className="admin-card admin-empty" data-testid="provider-empty">
					{t("providersEmpty")}
				</div>
			)}

			{!loading && !loadError && providers && providers.length > 0 && (
				<div className="grid gap-4">
					{providers.map((provider) => (
						<article
							key={provider.id}
							className="admin-card admin-card__body grid gap-4"
							data-testid={`provider-card-${provider.slug}`}
						>
							<div className="flex flex-wrap items-start justify-between gap-3">
								<div className="grid gap-1">
									<div className="flex flex-wrap items-center gap-2">
										<h3 className="text-base font-semibold text-ink">
											{provider.name}
										</h3>
										<code className="l-mono rounded bg-soft px-1.5 py-0.5 text-xs text-ink-2">
											{provider.slug}
										</code>
										<span className="rounded bg-soft px-1.5 py-0.5 text-xs text-ink-2">
											{provider.protocol === "anthropic"
												? t("protocolAnthropic")
												: t("protocolOpenai")}
										</span>
										<span
											className={
												provider.enabled
													? "text-xs text-emerald-400"
													: "text-xs text-ink-3"
											}
										>
											{provider.enabled
												? t("statusEnabled")
												: t("statusDisabled")}
										</span>
										<span className="text-xs text-ink-3">
											{t("priorityBadge", { priority: provider.priority })}
										</span>
									</div>
									<p className="font-mono text-xs text-ink-3">
										{provider.baseUrl}
									</p>
								</div>
								<div className="flex flex-wrap items-center gap-2">
									<button
										type="button"
										onClick={() => openEditForm(provider)}
										className="l-btn-outline text-xs"
									>
										{t("editAction")}
									</button>
									{confirmDeleteId === provider.id ? (
										<>
											<button
												type="button"
												disabled={busyProviderId === provider.id}
												onClick={() => void handleDeleteProvider(provider.id)}
												className="l-btn-outline text-xs text-red-400"
											>
												{t("confirmDelete")}
											</button>
											<button
												type="button"
												onClick={() => setConfirmDeleteId(null)}
												className="l-btn-outline text-xs"
											>
												{t("cancelAction")}
											</button>
										</>
									) : (
										<button
											type="button"
											onClick={() => setConfirmDeleteId(provider.id)}
											className="l-btn-outline text-xs text-red-400"
										>
											{t("deleteAction")}
										</button>
									)}
								</div>
							</div>

							<ProviderKeysSection provider={provider} onChanged={loadAll} />
							<ProviderModelsSection
								provider={provider}
								presets={presets}
								onChanged={loadAll}
							/>
						</article>
					))}
				</div>
			)}
		</div>
	);
}
