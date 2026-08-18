"use client";

import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { useMutation, useQuery } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import { copyText } from "@/lib/clipboard";
import { OFFERING_LABEL, type OfferingKind } from "@/lib/graphql/events";
import {
	CREATE_INVITE_BATCH,
	DISABLE_INVITE_BATCH,
	LIST_INVITE_BATCHES,
	type CreateInviteBatchInput,
	type InviteBatchFilter,
	type InviteBatchItem,
	type InviteBatchStatus,
} from "@/lib/graphql/invite-batch";

const PAGE_SIZE = 50;
const INVITE_CODE_CHARACTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

type InviteBatchDisplayStatus = InviteBatchStatus | "expired" | "exhausted";

type InviteBatchDraft = {
	inviteCode: string;
	quota: string;
	expiresAt: string;
	remark: string;
};

type FieldErrors = Partial<Record<"inviteCode" | "quota" | "expiresAt", string>>;

type ListState = {
	key: string;
	items: InviteBatchItem[];
	endKeyset: string | null;
};

type InviteBatchTranslate = ReturnType<typeof useTranslations<"inviteBatch">>;

const EMPTY_DRAFT: InviteBatchDraft = {
	inviteCode: "",
	quota: "1",
	expiresAt: "",
	remark: "",
};

const DISPLAY_STATUS_LABEL: Record<InviteBatchDisplayStatus, string> = {
	active: "statusActive",
	disabled: "statusDisabled",
	expired: "statusExpired",
	exhausted: "statusExhausted",
};

const DISPLAY_STATUS_CLASS: Record<InviteBatchDisplayStatus, string> = {
	active: "l-badge l-badge-success",
	disabled: "l-badge l-badge-muted",
	expired: "l-badge l-badge-muted",
	exhausted: "l-badge l-badge-muted",
};

export function deriveInviteBatchDisplayStatus(
	item: Pick<InviteBatchItem, "status" | "expiresAt" | "remainingQuota">,
	now = Date.now(),
): InviteBatchDisplayStatus {
	if (item.status === "disabled") return "disabled";

	if (item.expiresAt) {
		const expiresAt = new Date(item.expiresAt).getTime();
		if (!Number.isNaN(expiresAt) && expiresAt < now) return "expired";
	}

	if (item.remainingQuota === 0) return "exhausted";
	return "active";
}

export function inviteBatchBadgeClass(status: InviteBatchDisplayStatus): string {
	return DISPLAY_STATUS_CLASS[status];
}

function toLocalDateTimeInput(date: Date): string {
	const pad = (value: number) => String(value).padStart(2, "0");
	return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function fromLocalDateTimeInput(value: string): string | null {
	if (!value) return null;
	const date = new Date(value);
	return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function formatDateTime(t: InviteBatchTranslate, value: string | null): string {
	if (!value) return t("noExpiry");
	const date = new Date(value);
	if (Number.isNaN(date.getTime())) return t("invalidTime");
	return date.toLocaleString("zh-CN", {
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
	});
}

function generateInviteCode(length = 10): string {
	const characters = INVITE_CODE_CHARACTERS;
	const values = new Uint32Array(length);

	if (typeof globalThis.crypto !== "undefined" && globalThis.crypto.getRandomValues) {
		globalThis.crypto.getRandomValues(values);
		return Array.from(values, (value) => characters[value % characters.length]).join("");
	}

	return Array.from({ length }, () => {
		const index = Math.floor(Math.random() * characters.length);
		return characters[index];
	}).join("");
}

function friendlyCreateError(t: InviteBatchTranslate, message: string | null | undefined): string {
	if (
		message &&
		/(already been taken|already exists|unique|invite[_ ]?code|邀请码)/i.test(message)
	) {
		return t("createErrorTaken");
	}
	return message || t("createErrorFallback");
}

function friendlyDisableError(t: InviteBatchTranslate, message: string | null | undefined): string {
	return message || t("disableErrorFallback");
}

function createFilter(kind: OfferingKind, offeringId: string, workspaceId: string): InviteBatchFilter {
	return kind === "event"
		? { workspaceId: { eq: workspaceId }, eventId: { eq: offeringId } }
		: { workspaceId: { eq: workspaceId }, courseId: { eq: offeringId } };
}

export interface InviteBatchPanelProps {
	kind: OfferingKind;
	offeringId: string;
	offeringStatus: string;
	workspaceId: string;
}

export default function InviteBatchPanel({
	kind,
	offeringId,
	offeringStatus,
	workspaceId,
}: InviteBatchPanelProps) {
	const filter = useMemo(
		() => createFilter(kind, offeringId, workspaceId),
		[kind, offeringId, workspaceId],
	);
	const listKey = `${workspaceId}:${kind}:${offeringId}`;
	const minExpiresAt = toLocalDateTimeInput(new Date());
	const appliedQueryKey = useRef("");
	const [draft, setDraft] = useState<InviteBatchDraft>(EMPTY_DRAFT);
	const [fieldErrors, setFieldErrors] = useState<FieldErrors>({});
	const [formError, setFormError] = useState<string | null>(null);
	const [formMessage, setFormMessage] = useState<string | null>(null);
	const [listState, setListState] = useState<ListState>({
		key: "",
		items: [],
		endKeyset: null,
	});
	const [retrying, setRetrying] = useState(false);
	const [loadingMore, setLoadingMore] = useState(false);
	const [loadMoreError, setLoadMoreError] = useState<string | null>(null);
	const [confirmingId, setConfirmingId] = useState<string | null>(null);
	const [disableBusyId, setDisableBusyId] = useState<string | null>(null);
	const [disableErrors, setDisableErrors] = useState<Record<string, string>>({});
	const [copyStates, setCopyStates] = useState<
		Record<string, "success" | "error">
	>({});
	const { data, loading, error, refetch } = useQuery(LIST_INVITE_BATCHES, {
		variables: { filter, first: PAGE_SIZE, after: null },
		skip: !workspaceId || !offeringId,
		notifyOnNetworkStatusChange: true,
	});
	const [createInviteBatch, { loading: creating }] = useMutation(CREATE_INVITE_BATCH);
	const [disableInviteBatch] = useMutation(DISABLE_INVITE_BATCH);

	useEffect(() => {
		appliedQueryKey.current = "";
		setListState({ key: listKey, items: [], endKeyset: null });
		setLoadMoreError(null);
		setConfirmingId(null);
		setDisableErrors({});
	}, [listKey]);

	useEffect(() => {
		if (loading || error || !data?.inviteBatches || appliedQueryKey.current === listKey) return;

		appliedQueryKey.current = listKey;
		setListState({
			key: listKey,
			items: data.inviteBatches.results ?? [],
			endKeyset: data.inviteBatches.endKeyset ?? null,
		});
	}, [data, error, listKey, loading]);

	const stale = listState.key !== listKey;
	const listError = stale ? null : error;
	const items = stale ? [] : listState.items;
	const canCreate = offeringStatus === "open";
	const t = useTranslations("inviteBatch");
	const labelsT = useTranslations();
	const label = labelsT(OFFERING_LABEL[kind]);

	async function reloadFirstPage() {
		const response = await refetch({ filter, first: PAGE_SIZE, after: null });
		const page = response.data?.inviteBatches;
		if (!page) throw new Error(t("listRefreshFailed"));
		appliedQueryKey.current = listKey;
		setListState({
			key: listKey,
			items: page.results ?? [],
			endKeyset: page.endKeyset ?? null,
		});
		setLoadMoreError(null);
	}

	async function retryList() {
		setRetrying(true);
		try {
			await reloadFirstPage();
		} catch {
			// Apollo error remains visible through the query result; keep the explicit retry state local.
		} finally {
			setRetrying(false);
		}
	}

	async function loadMore() {
		if (loadingMore || !listState.endKeyset) return;
		setLoadingMore(true);
		setLoadMoreError(null);
		try {
			const response = await refetch({
				filter,
				first: PAGE_SIZE,
				after: listState.endKeyset,
			});
			const page = response.data?.inviteBatches;
			if (!page) throw new Error(t("pageLoadFailed"));
			setListState((previous) => ({
				...previous,
				items: [...previous.items, ...(page.results ?? [])],
				endKeyset: page.endKeyset ?? null,
			}));
		} catch (caught: unknown) {
			setLoadMoreError(caught instanceof Error ? caught.message : t("loadMoreError"));
		} finally {
			setLoadingMore(false);
		}
	}

	function updateDraft(patch: Partial<InviteBatchDraft>) {
		setDraft((previous) => ({ ...previous, ...patch }));
		setFieldErrors({});
		setFormError(null);
		setFormMessage(null);
	}

	function validateDraft(): FieldErrors {
		const next: FieldErrors = {};
		const inviteCode = draft.inviteCode.trim();
		const quota = Number(draft.quota);

		if (!inviteCode) {
			next.inviteCode = t("errorCodeRequired");
		} else if (!/^[A-Za-z0-9_-]{1,64}$/.test(inviteCode)) {
			next.inviteCode = t("errorCodeInvalid");
		}
		if (!Number.isInteger(quota) || quota < 1) next.quota = t("errorQuotaMin");
		if (draft.expiresAt) {
			const expiresAt = new Date(draft.expiresAt).getTime();
			if (Number.isNaN(expiresAt) || expiresAt <= Date.now()) {
				next.expiresAt = t("errorExpiryPast");
			}
		}
		return next;
	}

	async function submit(event: FormEvent<HTMLFormElement>) {
		event.preventDefault();
		if (!canCreate || creating) return;

		const nextErrors = validateDraft();
		setFieldErrors(nextErrors);
		setFormError(null);
		setFormMessage(null);
		if (Object.keys(nextErrors).length > 0) return;

		const input: CreateInviteBatchInput = {
			...(kind === "event" ? { eventId: offeringId } : { courseId: offeringId }),
			inviteCode: draft.inviteCode.trim(),
			quota: Number(draft.quota),
			expiresAt: fromLocalDateTimeInput(draft.expiresAt),
			remark: draft.remark.trim() || null,
		};

		try {
			const response = await createInviteBatch({ variables: { input } });
			const result = response.data?.createInviteBatch;
			if (!result?.result) {
				setFormError(friendlyCreateError(t, result?.errors?.[0]?.message));
				return;
			}
			setDraft(EMPTY_DRAFT);
			setFieldErrors({});
			setFormMessage(t("createSuccess"));
			await reloadFirstPage();
		} catch (caught: unknown) {
			setFormError(friendlyCreateError(t, caught instanceof Error ? caught.message : null));
		}
	}

	async function submitDisable(id: string) {
		if (disableBusyId) return;
		setDisableBusyId(id);
		setDisableErrors((previous) => {
			const next = { ...previous };
			delete next[id];
			return next;
		});
		try {
			const response = await disableInviteBatch({ variables: { id } });
			const result = response.data?.disableInviteBatch;
			if (!result?.result) {
				setDisableErrors((previous) => ({
					...previous,
					[id]: friendlyDisableError(t, result?.errors?.[0]?.message),
				}));
				return;
			}
			await reloadFirstPage();
			setConfirmingId(null);
		} catch (caught: unknown) {
			setDisableErrors((previous) => ({
				...previous,
				[id]: friendlyDisableError(t, caught instanceof Error ? caught.message : null),
			}));
		} finally {
			setDisableBusyId(null);
		}
	}

	async function copyInviteCode(item: InviteBatchItem) {
		const copied = await copyText(item.inviteCode);
		setCopyStates((previous) => ({ ...previous, [item.id]: copied ? "success" : "error" }));
		if (copied) {
			window.setTimeout(() => {
				setCopyStates((previous) => {
					if (previous[item.id] !== "success") return previous;
					const next = { ...previous };
					delete next[item.id];
					return next;
				});
			}, 2000);
		}
	}

	return (
		<section className="mt-4 rounded-large border border-line bg-card p-6">
			<h2 className="text-sm font-medium text-ink">{t("title")}</h2>
			<p className="mt-1 text-[13px] text-ink-3">{t("desc", { label })}</p>

			<form className="mt-4 grid gap-3" onSubmit={submit} noValidate>
				<div className="grid gap-3 sm:grid-cols-2">
					<div>
						<label htmlFor="invite-batch-invite-code" className="block text-[13px] text-ink-3">
							{t("inviteCode")}
						</label>
						<div className="mt-1 flex gap-2">
							<input
								id="invite-batch-invite-code"
								value={draft.inviteCode}
								onChange={(event) => updateDraft({ inviteCode: event.target.value })}
								disabled={!canCreate || creating}
								aria-invalid={Boolean(fieldErrors.inviteCode || formError)}
								aria-describedby="invite-batch-invite-code-help invite-batch-form-error"
								className="min-w-0 flex-1 rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink disabled:opacity-50"
							/>
							<button
								type="button"
								onClick={() => updateDraft({ inviteCode: generateInviteCode() })}
								disabled={!canCreate || creating}
								className="rounded-large border border-line-strong bg-card px-3 py-2 text-sm text-ink hover:border-line disabled:opacity-50"
							>
								{t("generate")}
							</button>
						</div>
						<p id="invite-batch-invite-code-help" className="mt-1 text-[12px] text-ink-3">
							{t("inviteCodeHelp")}
						</p>
						{fieldErrors.inviteCode ? (
							<p className="mt-1 text-[12px] text-danger" role="alert">
								{fieldErrors.inviteCode}
							</p>
						) : null}
					</div>

					<div>
						<label htmlFor="invite-batch-quota" className="block text-[13px] text-ink-3">
							{t("quota")}
						</label>
						<input
							id="invite-batch-quota"
							type="number"
							min={1}
							step={1}
							value={draft.quota}
							onChange={(event) => updateDraft({ quota: event.target.value })}
							disabled={!canCreate || creating}
							aria-invalid={Boolean(fieldErrors.quota)}
							aria-describedby="invite-batch-quota-help"
							className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink disabled:opacity-50"
						/>
						<p id="invite-batch-quota-help" className="mt-1 text-[12px] text-ink-3">
							{t("quotaHelp")}
						</p>
						{fieldErrors.quota ? (
							<p className="mt-1 text-[12px] text-danger" role="alert">
								{fieldErrors.quota}
							</p>
						) : null}
					</div>

					<div>
						<label htmlFor="invite-batch-expires-at" className="block text-[13px] text-ink-3">
							{t("expiresAt")}
						</label>
						<input
							id="invite-batch-expires-at"
							type="datetime-local"
							min={minExpiresAt}
							value={draft.expiresAt}
							onChange={(event) => updateDraft({ expiresAt: event.target.value })}
							disabled={!canCreate || creating}
							aria-invalid={Boolean(fieldErrors.expiresAt)}
							aria-describedby="invite-batch-expires-at-help"
							className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink disabled:opacity-50"
						/>
						<p id="invite-batch-expires-at-help" className="mt-1 text-[12px] text-ink-3">
							{t("expiresAtHelp")}
						</p>
						{fieldErrors.expiresAt ? (
							<p className="mt-1 text-[12px] text-danger" role="alert">
								{fieldErrors.expiresAt}
							</p>
						) : null}
					</div>

					<div>
						<label htmlFor="invite-batch-remark" className="block text-[13px] text-ink-3">
							{t("remark")}
						</label>
						<input
							id="invite-batch-remark"
							value={draft.remark}
							onChange={(event) => updateDraft({ remark: event.target.value })}
							disabled={!canCreate || creating}
							aria-describedby="invite-batch-remark-help"
							className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink disabled:opacity-50"
						/>
						<p id="invite-batch-remark-help" className="mt-1 text-[12px] text-ink-3">
							{t("remarkHelp")}
						</p>
					</div>
				</div>

				{!canCreate ? (
					<p className="text-[13px] text-ink-3" role="status">
						{t("cannotCreate")}
					</p>
				) : null}
				{formError ? (
					<p id="invite-batch-form-error" className="text-[13px] text-danger" role="alert">
						{formError}
					</p>
				) : (
					<span id="invite-batch-form-error" className="sr-only" />
				)}
				<div className="flex flex-wrap items-center gap-3">
					<button
						type="submit"
						disabled={!canCreate || creating}
						className="rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
					>
						{creating ? t("creating") : t("create")}
					</button>
					{formMessage ? (
						<span className="text-[13px] text-ink-3" role="status">
							{formMessage}
						</span>
					) : null}
				</div>
			</form>

			<div className="mt-6">
				<h3 className="text-[13px] font-medium text-ink">{t("listTitle")}</h3>
				{listError ? (
					<div className="mt-2 rounded-large border border-line bg-soft-2 p-3">
						<p className="text-[13px] text-danger" role="alert">
							{t("listError", { message: listError.message })}
						</p>
						<button
							type="button"
							disabled={retrying}
							onClick={() => void retryList()}
							className="mt-2 rounded-large border border-line-strong bg-card px-3 py-1.5 text-[13px] text-ink disabled:opacity-50"
						>
							{retrying ? t("retrying") : t("retry")}
						</button>
					</div>
				) : stale || (loading && items.length === 0) ? (
					<div className="mt-2 grid gap-2" aria-label={t("loadingAria")} aria-busy="true">
						<div className="h-12 animate-pulse rounded-large bg-soft-2" />
						<p className="text-[13px] text-ink-3">{t("loading")}</p>
					</div>
				) : items.length === 0 ? (
					<p className="mt-2 text-[13px] text-ink-3">{t("empty")}</p>
				) : (
					<>
						<ul className="mt-2 divide-y divide-line rounded-large border border-line">
							{items.map((item) => {
								const status = deriveInviteBatchDisplayStatus(item);
								const canDisable = status === "active" || status === "exhausted";
								const confirming = confirmingId === item.id;
								const busy = disableBusyId === item.id;
								const copyState = copyStates[item.id];
								return (
									<li key={item.id} className="flex flex-wrap items-start gap-3 px-4 py-3">
										<div className="min-w-0 flex-1">
											<div className="flex flex-wrap items-center gap-2">
												<code className="select-text text-sm font-medium text-ink">{item.inviteCode}</code>
												<span className={inviteBatchBadgeClass(status)}>
													{t(DISPLAY_STATUS_LABEL[status])}
												</span>
											</div>
											<p className="mt-1 text-[13px] text-ink-3">
												{t("usedCount", {
													used: item.quota - item.remainingQuota,
													total: item.quota,
												})}
												<span className="mx-1.5">·</span>
												{formatDateTime(t, item.expiresAt)}
											</p>
											{item.remark ? (
												<p className="mt-0.5 truncate text-[12px] text-ink-3">
													{t("remarkValue", { remark: item.remark })}
												</p>
											) : null}
											{disableErrors[item.id] ? (
												<p className="mt-1 text-[12px] text-danger" role="alert">
													{disableErrors[item.id]}
												</p>
											) : null}
										</div>

										<div className="flex flex-wrap items-center gap-2">
											<button
												type="button"
												onClick={() => void copyInviteCode(item)}
												aria-label={t("copyAria")}
												className="rounded-full border border-line px-2.5 py-1 text-[12px] text-ink-3 hover:border-line-strong"
											>
												{copyState === "success"
													? t("copied")
													: copyState === "error"
														? t("copyManual")
														: t("copy")}
											</button>
											{canDisable && !confirming ? (
												<button
													type="button"
													disabled={disableBusyId !== null}
													onClick={() => {
														setConfirmingId(item.id);
														setDisableErrors((previous) => {
															const next = { ...previous };
															delete next[item.id];
															return next;
														});
													}}
													className="rounded-full border border-line px-2.5 py-1 text-[12px] text-ink-3 hover:border-line-strong disabled:opacity-50"
												>
													{t("disable")}
												</button>
											) : null}
										</div>

										{confirming ? (
											<div className="w-full rounded-large border border-line bg-soft-2 p-3">
												<p className="text-[13px] text-ink-3">{t("disableConfirm")}</p>
												<div className="mt-2 flex gap-2">
													<button
														type="button"
														disabled={busy}
														onClick={() => void submitDisable(item.id)}
														className="rounded-large border border-danger px-3 py-1.5 text-[13px] text-danger disabled:opacity-50"
													>
														{busy ? t("submitting") : disableErrors[item.id] ? t("disableRetry") : t("confirmDisable")}
													</button>
													<button
														type="button"
														disabled={busy}
														onClick={() => {
															setConfirmingId(null);
															setDisableErrors((previous) => {
																const next = { ...previous };
																delete next[item.id];
																return next;
															});
														}}
														className="rounded-large border border-line px-3 py-1.5 text-[13px] text-ink-3 disabled:opacity-50"
													>
														{t("cancel")}
													</button>
												</div>
											</div>
										) : null}
								</li>
								);
							})}
						</ul>
						{loadMoreError ? (
							<p className="mt-2 text-[13px] text-danger" role="alert">
								{loadMoreError}
							</p>
						) : null}
						{listState.endKeyset ? (
							<button
								type="button"
								disabled={loadingMore}
								onClick={() => void loadMore()}
								className="mt-3 rounded-large border border-line-strong bg-card px-3 py-1.5 text-[13px] text-ink disabled:opacity-50"
							>
								{loadingMore ? t("loading") : t("loadMore")}
							</button>
						) : null}
					</>
				)}
			</div>
		</section>
	);
}
