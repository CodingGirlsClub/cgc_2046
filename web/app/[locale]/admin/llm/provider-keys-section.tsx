"use client";

import { type FormEvent, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import {
	ADMIN_ADD_LLM_PROVIDER_API_KEY,
	ADMIN_DELETE_LLM_PROVIDER_API_KEY,
	ADMIN_UPDATE_LLM_PROVIDER_API_KEY,
	type AdminLlmProvider,
	type AdminLlmProviderApiKey,
} from "@/lib/graphql/llm-providers";

interface ProviderKeysSectionProps {
	provider: AdminLlmProvider;
	onChanged: () => Promise<void>;
}

function errorMessage(err: unknown, fallback: string): string {
	return err instanceof Error && err.message ? err.message : fallback;
}

export default function ProviderKeysSection({
	provider,
	onChanged,
}: ProviderKeysSectionProps) {
	const t = useTranslations("adminLlm");
	const [label, setLabel] = useState("");
	const [apiKey, setApiKey] = useState("");
	const [adding, setAdding] = useState(false);
	const [busyKeyId, setBusyKeyId] = useState<string | null>(null);
	const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);
	const [error, setError] = useState<string | null>(null);
	const [status, setStatus] = useState<string | null>(null);

	async function handleAddKey(event: FormEvent) {
		event.preventDefault();
		setError(null);
		setStatus(null);

		const trimmedLabel = label.trim();
		const trimmedKey = apiKey.trim();
		if (!trimmedLabel) {
			setError(t("validationKeyLabel"));
			return;
		}
		if (!trimmedKey) {
			setError(t("validationApiKey"));
			return;
		}

		setAdding(true);
		try {
			const { data } = await client.mutate({
				mutation: ADMIN_ADD_LLM_PROVIDER_API_KEY,
				variables: {
					providerId: provider.id,
					label: trimmedLabel,
					apiKey: trimmedKey,
				},
			});
			if (!data?.adminAddLlmProviderApiKey) {
				setError(t("addKeyFailed"));
				return;
			}
			setLabel("");
			setApiKey("");
			setStatus(t("addKeySuccess", { preview: data.adminAddLlmProviderApiKey.keyPreview }));
			await onChanged();
		} catch (err) {
			setError(errorMessage(err, t("addKeyFailed")));
		} finally {
			setAdding(false);
		}
	}

	async function handleToggleKey(keyItem: AdminLlmProviderApiKey) {
		setError(null);
		setStatus(null);
		setBusyKeyId(keyItem.id);
		try {
			await client.mutate({
				mutation: ADMIN_UPDATE_LLM_PROVIDER_API_KEY,
				variables: { id: keyItem.id, enabled: !keyItem.enabled },
			});
			await onChanged();
		} catch (err) {
			setError(errorMessage(err, t("updateKeyFailed")));
		} finally {
			setBusyKeyId(null);
		}
	}

	async function handleDeleteKey(keyId: string) {
		setError(null);
		setStatus(null);
		setBusyKeyId(keyId);
		try {
			await client.mutate({
				mutation: ADMIN_DELETE_LLM_PROVIDER_API_KEY,
				variables: { id: keyId },
			});
			setConfirmDeleteId(null);
			await onChanged();
		} catch (err) {
			setError(errorMessage(err, t("deleteKeyFailed")));
		} finally {
			setBusyKeyId(null);
		}
	}

	return (
		<div className="grid gap-3 border-t border-line pt-4">
			<div className="flex flex-wrap items-center justify-between gap-2">
				<h4 className="text-xs font-semibold uppercase tracking-wide text-ink-2">
					{t("keysSectionTitle")} ({provider.apiKeys.length})
				</h4>
			</div>

			{provider.apiKeys.length === 0 ? (
				<p className="text-xs text-ink-3">{t("keysEmpty")}</p>
			) : (
				<div className="grid gap-2">
					{provider.apiKeys.map((keyItem) => (
						<div
							key={keyItem.id}
							className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-line bg-surface px-3 py-2 text-xs"
						>
							<div className="flex flex-wrap items-center gap-2">
								<span className="font-medium text-ink">{keyItem.label}</span>
								<code className="l-mono rounded bg-soft px-1.5 py-0.5 text-ink-2">
									{keyItem.keyPreview}
								</code>
								<span
									className={
										keyItem.enabled ? "text-emerald-400" : "text-ink-3"
									}
								>
									{keyItem.enabled ? t("statusEnabled") : t("statusDisabled")}
								</span>
							</div>
							<div className="flex items-center gap-2">
								<button
									type="button"
									disabled={busyKeyId === keyItem.id}
									onClick={() => void handleToggleKey(keyItem)}
									className="l-btn-outline text-xs"
								>
									{keyItem.enabled ? t("disableAction") : t("enableAction")}
								</button>
								{confirmDeleteId === keyItem.id ? (
									<>
										<button
											type="button"
											disabled={busyKeyId === keyItem.id}
											onClick={() => void handleDeleteKey(keyItem.id)}
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
										onClick={() => setConfirmDeleteId(keyItem.id)}
										className="l-btn-outline text-xs text-red-400"
									>
										{t("deleteAction")}
									</button>
								)}
							</div>
						</div>
					))}
				</div>
			)}

			<form
				onSubmit={(e) => void handleAddKey(e)}
				className="grid gap-2 sm:grid-cols-[1fr_2fr_auto] sm:items-end"
				data-testid={`provider-add-key-form-${provider.slug}`}
			>
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("keyLabelInput")}</span>
					<input
						type="text"
						value={label}
						onChange={(e) => setLabel(e.target.value)}
						placeholder={t("keyLabelPlaceholder")}
						className="l-input"
					/>
				</label>
				<label className="grid gap-1 text-xs text-ink-2">
					<span>{t("apiKeyInput")}</span>
					<input
						type="password"
						autoComplete="off"
						value={apiKey}
						onChange={(e) => setApiKey(e.target.value)}
						placeholder="sk-..."
						className="l-input"
					/>
				</label>
				<button type="submit" disabled={adding} className="l-btn-primary">
					{adding ? t("submitting") : t("addKeySubmit")}
				</button>
			</form>

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
		</div>
	);
}
