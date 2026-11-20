"use client";

/**
 * 工作台算力池管理页 /w/[slug]/llm-pool（Plan 008 Slice 3）。
 *
 * 门控：WorkspaceShell requireAbility="manage_members"（Owner/Admin 可管理；
 * PlatformAdmin 只读访客可审计余额与派发批次，隐藏写操作表单）。
 */

import { type FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { formatDateTime, fromLocalInput } from "@/lib/format";
import {
	CREATE_LLM_PAYMENT_ORDER,
	DISTRIBUTE_WORKSPACE_LLM_CREDITS,
	WORKSPACE_LLM_POOL,
	type LlmPaymentCheckout,
	type LlmPaymentProvider,
	type LlmWorkspacePoolSummary,
} from "@/lib/graphql/llm-gateway";
import {
	WORKSPACE_MEMBERS,
	type WorkspaceMembership,
} from "@/lib/graphql/workspace";
import {
	formatMcAsCny,
	formatMcInteger,
	parseCnyInputToCents,
	parseCnyInputToMc,
} from "@/lib/llm-credits";
import { PROVIDER_LABEL } from "@/lib/payment";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import LlmQrCheckout from "@/components/llm-qr-checkout";
import MembersTabs from "@/components/members-tabs";
import WorkspaceShell from "@/components/workspace-shell";

const TOPUP_PRESETS_CNY = ["100", "500", "1000", "5000"] as const;
const MIN_TOPUP_CENTS = 10_000; // ¥100
const MAX_TOPUP_CENTS = 10_000_000; // ¥100,000
const PROVIDERS: readonly LlmPaymentProvider[] = ["wechat_native", "alipay_qr"];
const ROLE_DISPLAY_ORDER = ["owner", "admin", "tutor", "learner"] as const;

type DistributeTargetMode = "all" | "roles" | "members";

const POOL_ENTRY_TYPE_KEYS: Record<string, string> = {
	migration_baseline: "entryMigrationBaseline",
	order_topup: "entryOrderTopup",
	admin_topup: "entryAdminTopup",
	batch_grant_debit: "entryBatchGrantDebit",
};

function formatSignedDeltaMc(deltaMc: string | number): string {
	const raw = typeof deltaMc === "number" ? BigInt(Math.trunc(deltaMc)) : BigInt(deltaMc);
	if (raw < BigInt(0)) {
		return `-${formatMcAsCny((-raw).toString())}`;
	}
	if (raw > BigInt(0)) {
		return `+${formatMcAsCny(raw.toString())}`;
	}
	return formatMcAsCny("0");
}

function errorMessage(err: unknown, fallback: string): string {
	if (!(err instanceof Error) || !err.message) return fallback;
	if (
		/^(Response not successful|Failed to fetch|NetworkError|Load failed)/i.test(
			err.message,
		)
	) {
		return fallback;
	}
	return err.message;
}

export default function WorkspaceLlmPoolPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const t = useTranslations("workspaceLlmPool");
	const tPages = useTranslations("workspacePages");
	const tCommon = useTranslations("common");
	const labelsT = useTranslations();

	const { ws, loading: wsLoading, readOnlyVisitor } = useWorkspaceBySlug(slug);
	const workspaceId = ws?.id ?? "";
	const canManage =
		!readOnlyVisitor && (ws?.myAbilities ?? []).includes("manage_members");

	const [pool, setPool] = useState<LlmWorkspacePoolSummary | null>(null);
	const [poolLoading, setPoolLoading] = useState(true);
	const [poolError, setPoolError] = useState<string | null>(null);

	// 扫码充值状态
	const [topupCny, setTopupCny] = useState("100");
	const [provider, setProvider] = useState<LlmPaymentProvider>("wechat_native");
	const [creatingOrder, setCreatingOrder] = useState(false);
	const [orderError, setOrderError] = useState<string | null>(null);
	const [activeCheckout, setActiveCheckout] = useState<{
		checkout: LlmPaymentCheckout;
		provider: LlmPaymentProvider;
	} | null>(null);

	// 批量派发状态
	const [targetMode, setTargetMode] = useState<DistributeTargetMode>("all");
	const [selectedRoles, setSelectedRoles] = useState<string[]>([]);
	const [selectedUserIds, setSelectedUserIds] = useState<string[]>([]);
	const [members, setMembers] = useState<WorkspaceMembership[]>([]);
	const [perMemberCny, setPerMemberCny] = useState("");
	const [expiresAtInput, setExpiresAtInput] = useState("");
	const [distributing, setDistributing] = useState(false);
	const [distributeError, setDistributeError] = useState<string | null>(null);
	const [distributeSuccess, setDistributeSuccess] = useState<string | null>(null);
	// 同一表单输入重试时复用 idempotencyKey，避免网络超时后重复扣池
	const pendingDistributeKeyRef = useRef<string | null>(null);

	const loadPool = useCallback(
		(id: string) => {
			if (!id) return Promise.resolve();
			setPoolLoading(true);
			setPoolError(null);
			return client
				.query({
					query: WORKSPACE_LLM_POOL,
					variables: { workspaceId: id },
					fetchPolicy: "network-only",
				})
				.then(({ data }) => {
					setPool(data?.workspaceLlmPool ?? null);
				})
				.catch((err) => {
					setPoolError(errorMessage(err, t("loadFailed")));
					setPool(null);
				})
				.finally(() => {
					setPoolLoading(false);
				});
		},
		[t],
	);

	useEffect(() => {
		if (!workspaceId) return;
		let cancelled = false;
		client
			.query({
				query: WORKSPACE_LLM_POOL,
				variables: { workspaceId },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				if (cancelled) return;
				setPool(data?.workspaceLlmPool ?? null);
				setPoolError(null);
			})
			.catch((err) => {
				if (cancelled) return;
				setPoolError(errorMessage(err, t("loadFailed")));
				setPool(null);
			})
			.finally(() => {
				if (!cancelled) setPoolLoading(false);
			});

		return () => {
			cancelled = true;
		};
	}, [workspaceId, t]);

	useEffect(() => {
		if (!workspaceId || !canManage) return;
		let cancelled = false;
		const PAGE_SIZE = 100;
		const MAX_PAGES = 50;

		async function loadAllMembers() {
			const collected: WorkspaceMembership[] = [];
			const seenUserIds = new Set<string>();
			let after: string | undefined;

			for (let page = 0; page < MAX_PAGES; page++) {
				const { data } = await client.query({
					query: WORKSPACE_MEMBERS,
					variables: {
						filter: { workspaceId: { eq: workspaceId } },
						first: PAGE_SIZE,
						...(after ? { after } : {}),
					},
					fetchPolicy: "network-only",
				});
				if (cancelled) return;
				const conn = data?.workspaceMembers;
				const batch = conn?.results ?? [];
				for (const member of batch) {
					if (!seenUserIds.has(member.userId)) {
						seenUserIds.add(member.userId);
						collected.push(member);
					}
				}
				const nextCursor = conn?.endKeyset ?? undefined;
				if (
					batch.length < PAGE_SIZE ||
					!nextCursor ||
					nextCursor === after ||
					(typeof conn?.count === "number" && collected.length >= conn.count)
				) {
					break;
				}
				after = nextCursor;
			}
			if (!cancelled) {
				setMembers(collected);
			}
		}

		loadAllMembers().catch(() => {
			if (!cancelled) setMembers([]);
		});

		return () => {
			cancelled = true;
		};
	}, [workspaceId, canManage]);

	const availableRoles = useMemo(() => {
		const present = new Set<string>();
		for (const member of members) {
			for (const role of member.roles ?? []) {
				if (role.name) present.add(role.name);
			}
		}
		const ordered: string[] = [];
		for (const role of ROLE_DISPLAY_ORDER) {
			if (present.delete(role)) ordered.push(role);
		}
		return [...ordered, ...Array.from(present).sort()];
	}, [members]);

	const perMemberMcPreview = useMemo(
		() => parseCnyInputToMc(perMemberCny),
		[perMemberCny],
	);

	const handleOrderPaid = useCallback(() => {
		if (workspaceId) void loadPool(workspaceId);
	}, [workspaceId, loadPool]);

	async function handleCreateTopupOrder(event: FormEvent) {
		event.preventDefault();
		if (!workspaceId) return;
		setOrderError(null);

		const amountCents = parseCnyInputToCents(topupCny);
		if (
			amountCents === null ||
			amountCents < MIN_TOPUP_CENTS ||
			amountCents > MAX_TOPUP_CENTS
		) {
			setOrderError(t("validationTopupRange"));
			return;
		}

		setCreatingOrder(true);
		try {
			const { data } = await client.mutate({
				mutation: CREATE_LLM_PAYMENT_ORDER,
				variables: {
					orderKind: "llm_workspace_pool_topup",
					provider,
					amountCents,
					workspaceId,
					idempotencyKey: crypto.randomUUID(),
				},
			});
			const checkout = data?.createLlmPaymentOrder;
			if (!checkout) {
				setOrderError(t("createOrderFailed"));
				return;
			}
			setActiveCheckout({ checkout, provider });
			if (checkout.order.status === "paid") {
				void loadPool(workspaceId);
			}
		} catch (err) {
			setOrderError(errorMessage(err, t("createOrderFailed")));
		} finally {
			setCreatingOrder(false);
		}
	}

	async function handleDistribute(event: FormEvent) {
		event.preventDefault();
		if (!workspaceId) return;
		setDistributeError(null);
		setDistributeSuccess(null);

		const perMemberMc = parseCnyInputToMc(perMemberCny);
		if (perMemberMc === null) {
			setDistributeError(t("validationPerMember"));
			return;
		}
		if (targetMode === "roles" && selectedRoles.length === 0) {
			setDistributeError(t("validationTargetRoles"));
			return;
		}
		if (targetMode === "members" && selectedUserIds.length === 0) {
			setDistributeError(t("validationTargetMembers"));
			return;
		}

		const idempotencyKey =
			pendingDistributeKeyRef.current ?? crypto.randomUUID();
		pendingDistributeKeyRef.current = idempotencyKey;
		const expiresAt = expiresAtInput ? fromLocalInput(expiresAtInput) : null;

		setDistributing(true);
		try {
			const { data } = await client.mutate({
				mutation: DISTRIBUTE_WORKSPACE_LLM_CREDITS,
				variables: {
					workspaceId,
					perMemberMc: perMemberMc.toString(),
					idempotencyKey,
					expiresAt,
					...(targetMode === "roles" ? { targetRoles: selectedRoles } : {}),
					...(targetMode === "members" ? { targetUserIds: selectedUserIds } : {}),
				},
			});
			const result = data?.distributeWorkspaceLlmCredits;
			if (!result) {
				setDistributeError(t("distributeFailed"));
				return;
			}
			pendingDistributeKeyRef.current = null;
			setDistributeSuccess(
				result.idempotentReplay
					? t("distributeReplay", {
							count: result.memberCount,
							total: formatMcAsCny(result.totalGrantedMc),
						})
					: t("distributeSuccess", {
							count: result.memberCount,
							perMember: formatMcAsCny(result.perMemberMc),
							total: formatMcAsCny(result.totalGrantedMc),
						}),
			);
			setPerMemberCny("");
			setExpiresAtInput("");
			void loadPool(workspaceId);
		} catch (err) {
			setDistributeError(errorMessage(err, t("distributeFailed")));
		} finally {
			setDistributing(false);
		}
	}

	return (
		<WorkspaceShell slug={slug} requireAbility="manage_members">
			<div className="ws-page-main__inner">
				<div
					className="ws-page-breadcrumb"
					aria-label={tCommon("breadcrumbAria")}
				>
					<Link href="/">{tPages("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>{t("title")}</strong>
				</div>

				{ws ? (
					<MembersTabs
						slug={slug}
						current="llm-pool"
						abilities={ws.myAbilities ?? []}
					/>
				) : null}

				<header className="ws-page-heading mt-5">
					<div>
						<h1>{t("title")}</h1>
						<p>{t("subtitle")}</p>
					</div>
				</header>

				{wsLoading || (poolLoading && !pool && !poolError) ? (
					<div
						className="admin-card admin-empty"
						data-testid="workspace-pool-loading"
					>
						{t("loading")}
					</div>
				) : poolError ? (
					<div
						className="admin-card admin-card__body flex flex-wrap items-center justify-between gap-3"
						role="alert"
						data-testid="workspace-pool-error"
					>
						<p className="text-sm text-red-400">{poolError}</p>
						<button
							type="button"
							onClick={() => void loadPool(workspaceId)}
							className="l-btn-outline"
						>
							{tCommon("retry")}
						</button>
					</div>
				) : !pool ? (
					<div
						className="admin-card admin-empty"
						data-testid="workspace-pool-empty"
					>
						{t("emptyPool")}
					</div>
				) : (
					<div className="grid gap-6">
						{/* 算力池余额总览 */}
						<div
							className="admin-card admin-card__body"
							data-testid="workspace-pool-summary"
						>
							<div className="flex flex-wrap items-baseline justify-between gap-4">
								<div>
									<span className="admin-stat__label">{t("poolBalanceLabel")}</span>
									<span
										className="admin-stat__value mt-1"
										data-testid="workspace-pool-cny"
									>
										{formatMcAsCny(pool.creditPoolMc)}
									</span>
									<p
										className="mt-1 font-mono text-xs text-ink-3"
										data-testid="workspace-pool-mc"
									>
										{formatMcInteger(pool.creditPoolMc)} mc
									</p>
								</div>
								<div className="text-right">
									<p className="text-xs text-ink-3">
										{t("updatedAt", {
											time: formatDateTime(pool.updatedAt),
										})}
									</p>
									<button
										type="button"
										onClick={() => void loadPool(workspaceId)}
										disabled={poolLoading}
										className="l-btn-outline mt-2"
									>
										{t("refresh")}
									</button>
								</div>
							</div>
						</div>

						{canManage && (
							<div className="grid gap-4 lg:grid-cols-2">
								{/* 扫码充值面板 */}
								<div className="admin-card admin-card__body">
									<div>
										<h2 className="text-sm font-medium text-ink">
											{t("topupTitle")}
										</h2>
										<p className="mt-1 text-xs text-ink-3">
											{t("topupDesc")}
										</p>
									</div>

									{activeCheckout ? (
										<LlmQrCheckout
											order={activeCheckout.checkout.order}
											provider={activeCheckout.provider}
											credential={activeCheckout.checkout.credential}
											onPaid={handleOrderPaid}
											onReset={() => setActiveCheckout(null)}
										/>
									) : (
										<form
											onSubmit={(e) => void handleCreateTopupOrder(e)}
											className="grid gap-3"
											data-testid="workspace-topup-form"
										>
											<div className="flex flex-wrap gap-2">
												{TOPUP_PRESETS_CNY.map((preset) => (
													<button
														key={preset}
														type="button"
														onClick={() => setTopupCny(preset)}
														className={
															topupCny === preset
																? "l-btn-primary"
																: "l-btn-outline"
														}
													>
														¥{preset}
													</button>
												))}
											</div>

											<label className="grid gap-1.5 text-xs text-ink-2">
												<span>{t("topupAmountLabel")}</span>
												<input
													type="text"
													inputMode="decimal"
													value={topupCny}
													onChange={(e) => setTopupCny(e.target.value)}
													placeholder="100"
													className="l-input"
												/>
												<span className="text-xs text-ink-3">
													{t("topupAmountHint")}
												</span>
											</label>

											<div className="grid gap-1.5 text-xs text-ink-2">
												<span>{t("providerLabel")}</span>
												<div className="flex flex-wrap gap-2">
													{PROVIDERS.map((p) => (
														<button
															key={p}
															type="button"
															aria-pressed={provider === p}
															onClick={() => setProvider(p)}
															className={
																provider === p
																	? "l-btn-primary"
																	: "l-btn-outline"
															}
														>
															{PROVIDER_LABEL[p]
																? labelsT(PROVIDER_LABEL[p])
																: p}
														</button>
													))}
												</div>
											</div>

											{orderError && (
												<p role="alert" className="text-xs text-red-400">
													{orderError}
												</p>
											)}

											<div>
												<button
													type="submit"
													disabled={creatingOrder}
													className="l-btn-primary"
												>
													{creatingOrder
														? t("creatingOrder")
														: t("createOrderSubmit")}
												</button>
											</div>
										</form>
									)}
								</div>

								{/* 批量派发面板 */}
								<form
									onSubmit={(e) => void handleDistribute(e)}
									className="admin-card admin-card__body"
									data-testid="workspace-distribute-form"
								>
									<div>
										<h2 className="text-sm font-medium text-ink">
											{t("distributeTitle")}
										</h2>
										<p className="mt-1 text-xs text-ink-3">
											{t("distributeDesc")}
										</p>
									</div>

									<div className="grid gap-1.5 text-xs text-ink-2">
										<span>{t("targetModeLabel")}</span>
										<div className="flex flex-wrap gap-2">
											{(["all", "roles", "members"] as const).map((mode) => (
												<button
													key={mode}
													type="button"
													data-testid={`target-mode-${mode}`}
													aria-pressed={targetMode === mode}
													onClick={() => {
														pendingDistributeKeyRef.current = null;
														setDistributeError(null);
														setTargetMode(mode);
													}}
													className={`l-btn-secondary ${
														targetMode === mode
															? "border-accent text-ink"
															: ""
													}`}
												>
													{mode === "all"
														? t("targetModeAll")
														: mode === "roles"
															? t("targetModeRoles")
															: t("targetModeMembers")}
												</button>
											))}
										</div>
									</div>

									{targetMode === "roles" && (
										<div
											className="grid gap-1.5 text-xs text-ink-2"
											data-testid="target-roles-selector"
										>
											<span>{t("targetRolesLabel")}</span>
											{availableRoles.length === 0 ? (
												<p className="text-xs text-ink-3">
													{t("targetMembersEmpty")}
												</p>
											) : (
												<div className="flex flex-wrap gap-3">
													{availableRoles.map((role) => {
														const checked = selectedRoles.includes(role);
														return (
															<label
																key={role}
																className="inline-flex items-center gap-1.5 text-xs text-ink"
															>
																<input
																	type="checkbox"
																	checked={checked}
																	onChange={() => {
																		pendingDistributeKeyRef.current = null;
																		setSelectedRoles((prev) =>
																			checked
																				? prev.filter((item) => item !== role)
																				: [...prev, role],
																		);
																	}}
																/>
																<span>{role}</span>
															</label>
														);
													})}
												</div>
											)}
										</div>
									)}

									{targetMode === "members" && (
										<div
											className="grid gap-1.5 text-xs text-ink-2"
											data-testid="target-members-selector"
										>
											<span>{t("targetMembersLabel")}</span>
											{members.length === 0 ? (
												<p className="text-xs text-ink-3">
													{t("targetMembersEmpty")}
												</p>
											) : (
												<div className="grid max-h-36 gap-1.5 overflow-y-auto rounded border border-border-1 p-2">
													{members.map((member) => {
														const checked = selectedUserIds.includes(
															member.userId,
														);
														const label =
															member.userDisplayName ||
															member.userEmail ||
															member.userId;
														const roleNames = (member.roles ?? [])
															.map((r) => r.name)
															.filter(Boolean)
															.join(", ");
														return (
															<label
																key={member.userId}
																className="inline-flex items-center gap-2 text-xs text-ink"
															>
																<input
																	type="checkbox"
																	checked={checked}
																	onChange={() => {
																		pendingDistributeKeyRef.current = null;
																		setSelectedUserIds((prev) =>
																			checked
																				? prev.filter(
																						(id) => id !== member.userId,
																					)
																				: [...prev, member.userId],
																		);
																	}}
																/>
																<span>{label}</span>
																{roleNames && (
																	<span className="text-ink-3">
																		({roleNames})
																	</span>
																)}
															</label>
														);
													})}
												</div>
											)}
										</div>
									)}

									<label className="grid gap-1.5 text-xs text-ink-2">
										<span>{t("perMemberLabel")}</span>
										<input
											type="text"
											inputMode="decimal"
											value={perMemberCny}
											onChange={(e) => {
												pendingDistributeKeyRef.current = null;
												setPerMemberCny(e.target.value);
											}}
											placeholder="10.00"
											className="l-input"
										/>
										{perMemberMcPreview !== null && (
											<span className="font-mono text-xs text-ink-3">
												= {formatMcInteger(perMemberMcPreview)} mc
											</span>
										)}
									</label>

									<label className="grid gap-1.5 text-xs text-ink-2">
										<span>{t("expiresAtLabel")}</span>
										<input
											type="datetime-local"
											value={expiresAtInput}
											onChange={(e) => {
												pendingDistributeKeyRef.current = null;
												setExpiresAtInput(e.target.value);
											}}
											className="l-input"
										/>
										<span className="text-xs text-ink-3">
											{t("expiresAtHint")}
										</span>
									</label>

									{distributeError && (
										<p role="alert" className="text-xs text-red-400">
											{distributeError}
										</p>
									)}
									{distributeSuccess && (
										<p role="status" className="text-xs text-emerald-400">
											{distributeSuccess}
										</p>
									)}

									<div>
										<button
											type="submit"
											disabled={distributing}
											className="l-btn-primary"
										>
											{distributing
												? t("distributing")
												: t("distributeSubmit")}
										</button>
									</div>
								</form>
							</div>
						)}

						{/* 最近派发批次审计表 */}
						<div>
							<h2 className="admin-section-title">{t("batchesTitle")}</h2>
							{pool.recentBatches.length === 0 ? (
								<div
									className="admin-card admin-empty"
									data-testid="workspace-batches-empty"
								>
									{t("batchesEmpty")}
								</div>
							) : (
								<div className="admin-card admin-table-wrap">
									<table
										className="admin-table"
										data-testid="workspace-batches-table"
									>
										<thead>
											<tr>
												<th>{t("thBatchTime")}</th>
												<th className="admin-table__num">{t("thPerMember")}</th>
												<th className="admin-table__num">{t("thMembers")}</th>
												<th className="admin-table__num">{t("thTotalGranted")}</th>
												<th>{t("thExpiresAt")}</th>
												<th>{t("thActor")}</th>
												<th>{t("thIdempotencyKey")}</th>
											</tr>
										</thead>
										<tbody>
											{pool.recentBatches.map((batch) => (
												<tr key={batch.id}>
													<td>{formatDateTime(batch.insertedAt)}</td>
													<td className="admin-table__num">
														{formatMcAsCny(batch.perMemberMc)}
													</td>
													<td className="admin-table__num">
														{batch.memberCount}
													</td>
													<td className="admin-table__num admin-table__primary">
														{formatMcAsCny(batch.totalGrantedMc)}
													</td>
													<td>
														{batch.expiresAt
															? formatDateTime(batch.expiresAt)
															: t("permanent")}
													</td>
													<td className="l-mono">{batch.actorUserId}</td>
													<td className="l-mono">{batch.idempotencyKey}</td>
												</tr>
											))}
										</tbody>
									</table>
								</div>
							)}
						</div>

						{/* 共享池账本流水 */}
						<div>
							<h2 className="admin-section-title">{t("entriesTitle")}</h2>
							{(pool.recentPoolEntries ?? []).length === 0 ? (
								<div
									className="admin-card admin-empty"
									data-testid="workspace-pool-entries-empty"
								>
									{t("entriesEmpty")}
								</div>
							) : (
								<div className="admin-card admin-table-wrap">
									<table
										className="admin-table"
										data-testid="workspace-pool-entries-table"
									>
										<thead>
											<tr>
												<th>{t("thEntryTime")}</th>
												<th>{t("thEntryType")}</th>
												<th className="admin-table__num">{t("thEntryDelta")}</th>
												<th>{t("thEntryRef")}</th>
												<th>{t("thActor")}</th>
											</tr>
										</thead>
										<tbody>
											{(pool.recentPoolEntries ?? []).map((entry) => {
												const typeKey = POOL_ENTRY_TYPE_KEYS[entry.entryType];
												const refId =
													entry.paymentOrderId ??
													entry.workspaceBatchId ??
													"—";
												return (
													<tr key={entry.id}>
														<td>{formatDateTime(entry.insertedAt)}</td>
														<td>
															{typeKey ? t(typeKey) : entry.entryType}
														</td>
														<td className="admin-table__num admin-table__primary">
															{formatSignedDeltaMc(entry.deltaMc)}
														</td>
														<td className="l-mono">{refId}</td>
														<td className="l-mono">
															{entry.actorUserId ?? "—"}
														</td>
													</tr>
												);
											})}
										</tbody>
									</table>
								</div>
							)}
						</div>
					</div>
				)}
			</div>
		</WorkspaceShell>
	);
}
