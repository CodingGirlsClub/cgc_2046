"use client";

/**
 * 招募审核面板 /w/[slug]/recruitment（R13；U8）。
 *
 * 受众：该工作台 Owner/Admin（platform_admin 穿透）——门控由服务端 policy 兜底
 * （非管理角色调用 → forbidden 抛出，本页显示错误态）。
 *
 * 能力：
 * - 批次区：列表（状态徽章）+ 新建（名称/截止）+ 开放/关闭（同台已有 open →
 *   稳定 code `recruitment_cohort_open_conflict` 文案）
 * - 申请区：批次/状态过滤 + 列表；行内「推进 / 分配 / 拒绝 / 取消」；
 *   详情展开显示申请人档案元数据 + 简历下载（受保护端点，安全响应头）
 * - 分配（training → assigned）：从该台场次中选一场 + 备注；R15 的副作用
 *   （入台 + 角色映射 + EventModerator 指派）由后端同事务完成，失败整体回滚
 *
 * 错误文案：业务 code → `errors.<code>`（#241 惯例）；无文案时回落通用句。
 */

import { useCallback, useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { fetchWorkspaceOfferings } from "@/lib/events";
import type { OfferingItem } from "@/lib/graphql/events";
import WorkspaceShell from "@/components/workspace-shell";
import {
	advanceVolunteerApplication,
	assignVolunteerApplication,
	cancelVolunteerApplication,
	closeRecruitmentCohort,
	createRecruitmentCohort,
	fetchRecruitmentCohorts,
	fetchVolunteerApplicationDetail,
	fetchVolunteerApplications,
	openRecruitmentCohort,
	rejectVolunteerApplication,
	type AdminVolunteerApplication,
	type RecruitmentCohort,
	type VolunteerApplicationDetail,
	type VolunteerApplicationStatus,
} from "@/lib/graphql/recruitment";

/** 段位 → 徽章色调（审核面用） */
const STATUS_TONE: Record<VolunteerApplicationStatus, string> = {
	submitted: "open",
	interview: "open",
	training: "open",
	assigned: "confirmed",
	rejected: "closed",
	canceled: "cancelled",
};

/** 可推进的下一段（submitted → interview → training；training 走分配） */
function nextStage(status: VolunteerApplicationStatus): "interview" | "training" | null {
	if (status === "submitted") return "interview";
	if (status === "interview") return "training";
	return null;
}

/** 可操作（未终结）的段位 */
function isActive(status: VolunteerApplicationStatus): boolean {
	return status === "submitted" || status === "interview" || status === "training";
}

export default function RecruitmentPanelPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const t = useTranslations("recruitmentPanel");
	const errorsT = useTranslations("errors");
	const { ws } = useWorkspaceBySlug(slug);
	const workspaceId = ws?.id ?? "";

	const [cohorts, setCohorts] = useState<RecruitmentCohort[] | null>(null);
	const [applications, setApplications] = useState<AdminVolunteerApplication[] | null>(null);
	const [events, setEvents] = useState<OfferingItem[] | null>(null);
	const [loadError, setLoadError] = useState(false);

	const [filterCohort, setFilterCohort] = useState("");
	const [filterStatus, setFilterStatus] = useState("");

	const [busyId, setBusyId] = useState<string | null>(null);
	const [actionError, setActionError] = useState<string | null>(null);

	// 行内展开态（同一时刻只展开一个操作；null = 无）
	const [details, setDetails] = useState<Record<string, VolunteerApplicationDetail | null>>({});
	const [rejectTarget, setRejectTarget] = useState<string | null>(null);
	const [rejectReason, setRejectReason] = useState("");
	const [assignTarget, setAssignTarget] = useState<string | null>(null);
	const [assignEventId, setAssignEventId] = useState("");
	const [assignNote, setAssignNote] = useState("");
	const [cancelTarget, setCancelTarget] = useState<string | null>(null);
	const [cancelNote, setCancelNote] = useState("");

	// 批次新建表单
	const [newName, setNewName] = useState("");
	const [newDeadline, setNewDeadline] = useState("");

	const codeMessage = useCallback(
		(code: string | null | undefined, fallback: string) =>
			code && errorsT.has(code) ? errorsT(code) : fallback,
		[errorsT],
	);

	const reload = useCallback(() => {
		if (!workspaceId) return;
		setLoadError(false);
		void Promise.all([
			fetchRecruitmentCohorts(workspaceId),
			fetchVolunteerApplications(workspaceId, {
				cohortId: filterCohort || null,
				status: filterStatus || null,
			}),
			fetchWorkspaceOfferings(workspaceId, "event"),
		])
			.then(([cohortRows, applicationRows, eventRows]) => {
				setCohorts(cohortRows);
				setApplications(applicationRows);
				setEvents(eventRows);
			})
			.catch(() => {
				setLoadError(true);
				setCohorts([]);
				setApplications([]);
			});
	}, [workspaceId, filterCohort, filterStatus]);

	useEffect(() => {
		reload();
	}, [reload]);

	/** 统一的操作执行：mutation → 成功 reload 并返回 true；失败取稳定 code 文案并返回 false */
	const run = useCallback(
		async (
			id: string,
			action: () => Promise<{ result: unknown; errors: Array<{ code: string | null }> }>,
		): Promise<boolean> => {
			setBusyId(id);
			setActionError(null);
			try {
				const outcome = await action();
				if (outcome.result) {
					setRejectTarget(null);
					setRejectReason("");
					setAssignTarget(null);
					setAssignEventId("");
					setAssignNote("");
					setCancelTarget(null);
					setCancelNote("");
					reload();
					return true;
				}
				setActionError(codeMessage(outcome.errors[0]?.code, t("actionFailed")));
				return false;
			} catch {
				setActionError(t("actionFailed"));
				return false;
			} finally {
				setBusyId(null);
			}
		},
		[codeMessage, reload, t],
	);

	const toggleDetail = useCallback(
		(id: string) => {
			if (details[id] !== undefined) {
				setDetails((current) => {
					const next = { ...current };
					delete next[id];
					return next;
				});
				return;
			}
			void fetchVolunteerApplicationDetail(workspaceId, id)
				.then((detail) => setDetails((current) => ({ ...current, [id]: detail })))
				.catch(() => setDetails((current) => ({ ...current, [id]: null })));
		},
		[details, workspaceId],
	);

	// 分配选择器：该台的 draft/open 场次（预建场次为 draft，发布后 open）
	const assignableEvents = (events ?? []).filter(
		(event) => event.status === "draft" || event.status === "open",
	);

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={t("breadcrumbAria")}>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>{t("title")}</strong>
				</div>

				<div className="ws-page-head">
					<h1 className="ws-page-title">{t("title")}</h1>
					<p className="ws-page-desc">{t("description")}</p>
				</div>

				{loadError ? (
					<div className="public-catalog-state" role="alert">
						<p>{t("loadFailed")}</p>
						<button type="button" className="public-catalog-retry" onClick={reload}>
							{t("retry")}
						</button>
					</div>
				) : (
					<>
						{/* 批次区：列表 + 新建 + 开放/关闭 */}
						<section aria-labelledby="rp-cohorts" className="rp-section">
							<h2 id="rp-cohorts" className="rp-section__title">
								{t("cohorts.title")}
							</h2>
							{cohorts === null ? (
								<p className="rp-muted">{t("loading")}</p>
							) : cohorts.length === 0 ? (
								<p className="rp-muted">{t("cohorts.empty")}</p>
							) : (
								<ul className="rp-cohort-list">
									{cohorts.map((cohort) => (
										<li key={cohort.id} className="rp-cohort">
											<span className="rp-cohort__name">{cohort.name}</span>
											<span className={`rp-badge rp-badge--${cohort.status}`}>
												{t(`cohorts.status.${cohort.status}`)}
											</span>
											<span className="rp-muted">
												{t("cohorts.deadline", {
													date: new Date(cohort.applyDeadlineAt).toISOString().slice(0, 10),
												})}
											</span>
											{cohort.status !== "open" ? (
												<button
													type="button"
													className="rp-action"
													disabled={busyId === cohort.id}
													onClick={() =>
														void run(cohort.id, () => openRecruitmentCohort(workspaceId, cohort.id))
													}
												>
													{t("cohorts.open")}
												</button>
											) : (
												<button
													type="button"
													className="rp-action"
													disabled={busyId === cohort.id}
													onClick={() =>
														void run(cohort.id, () => closeRecruitmentCohort(workspaceId, cohort.id))
													}
												>
													{t("cohorts.close")}
												</button>
											)}
										</li>
									))}
								</ul>
							)}

							<form
								className="rp-cohort-form"
								onSubmit={(event) => {
									event.preventDefault();
									// 截止时刻写死北京时间 23:59（用户群体在 UTC+8；写 Z 会让
									// 实际截止漂到次日 07:59，申请人多出 8 小时窗口）
									const deadline = new Date(`${newDeadline}T23:59:00+08:00`);
									void run("__new_cohort__", () =>
										createRecruitmentCohort(workspaceId, {
											name: newName,
											applyDeadlineAt: deadline.toISOString(),
										}),
									).then((ok) => {
										// 失败保留输入（错误文案已展示），服务端拒绝时管理员不必重敲
										if (ok) {
											setNewName("");
											setNewDeadline("");
										}
									});
								}}
							>
								<input
									className="rp-input"
									value={newName}
									onChange={(event) => setNewName(event.target.value)}
									placeholder={t("cohorts.namePlaceholder")}
									required
								/>
								<input
									className="rp-input"
									type="date"
									value={newDeadline}
									onChange={(event) => setNewDeadline(event.target.value)}
									aria-label={t("cohorts.deadlineLabel")}
									required
								/>
								<button type="submit" className="rp-action" disabled={busyId === "__new_cohort__"}>
									{t("cohorts.create")}
								</button>
							</form>
						</section>

						{/* 申请区：过滤 + 列表 + 行内操作 */}
						<section aria-labelledby="rp-applications" className="rp-section">
							<h2 id="rp-applications" className="rp-section__title">
								{t("applications.title")}
							</h2>
							<div className="rp-filters">
								<select
									className="rp-input"
									value={filterCohort}
									onChange={(event) => setFilterCohort(event.target.value)}
									aria-label={t("applications.filterCohort")}
								>
									<option value="">{t("applications.allCohorts")}</option>
									{(cohorts ?? []).map((cohort) => (
										<option key={cohort.id} value={cohort.id}>
											{cohort.name}
										</option>
									))}
								</select>
								<select
									className="rp-input"
									value={filterStatus}
									onChange={(event) => setFilterStatus(event.target.value)}
									aria-label={t("applications.filterStatus")}
								>
									<option value="">{t("applications.allStatuses")}</option>
									{(["submitted", "interview", "training", "assigned", "rejected", "canceled"] as const).map(
										(status) => (
											<option key={status} value={status}>
												{t(`status.${status}`)}
											</option>
										),
									)}
								</select>
							</div>

							{actionError ? (
								<p className="rp-error" role="alert">
									{actionError}
								</p>
							) : null}

							{applications === null ? (
								<p className="rp-muted">{t("loading")}</p>
							) : applications.length === 0 ? (
								<p className="rp-muted">{t("applications.empty")}</p>
							) : (
								<ul className="rp-app-list">
									{applications.map((application) => {
										const stage = nextStage(application.status);
										const detail = details[application.id];
										return (
											<li key={application.id} className="rp-app">
												<div className="rp-app__row">
													<span className="rp-app__position">{t(`positions.${application.position}`)}</span>
													<span className="rp-app__city">{application.city ?? t("applications.remote")}</span>
													<span
														className={`rp-badge rp-badge--${STATUS_TONE[application.status]}`}
													>
														{t(`status.${application.status}`)}
													</span>
													<button
														type="button"
														className="rp-link"
														onClick={() => toggleDetail(application.id)}
													>
														{t("applications.detail")}
													</button>

													{/* 行内操作 */}
													{stage ? (
														<button
															type="button"
															className="rp-action"
															disabled={busyId === application.id}
															onClick={() =>
																void run(application.id, () =>
																	advanceVolunteerApplication(workspaceId, application.id, stage),
																)
															}
														>
															{t(`actions.advance_${stage}`)}
														</button>
													) : null}
													{application.status === "training" ? (
														<button
															type="button"
															className="rp-action"
															onClick={() => {
																setAssignTarget(application.id);
																setRejectTarget(null);
																setCancelTarget(null);
															}}
														>
															{t("actions.assign")}
														</button>
													) : null}
													{isActive(application.status) ? (
														<>
															<button
																type="button"
																className="rp-action"
																onClick={() => {
																	setRejectTarget(application.id);
																	setRejectReason("");
																	setAssignTarget(null);
																	setCancelTarget(null);
																}}
															>
																{t("actions.reject")}
															</button>
															<button
																type="button"
																className="rp-action"
																onClick={() => {
																	setCancelTarget(application.id);
																	setCancelNote("");
																	setRejectTarget(null);
																	setAssignTarget(null);
																}}
															>
																{t("actions.cancel")}
															</button>
														</>
													) : null}
												</div>

												{/* 拒绝：原因必填（前端拦截空值；服务端仍兜底） */}
												{rejectTarget === application.id ? (
													<div className="rp-inline-form">
														<input
															className="rp-input"
															value={rejectReason}
															onChange={(event) => setRejectReason(event.target.value)}
															placeholder={t("reject.reasonPlaceholder")}
															aria-label={t("reject.reasonLabel")}
														/>
														<button
															type="button"
															className="rp-action rp-action--danger"
															disabled={busyId === application.id || rejectReason.trim() === ""}
															onClick={() =>
																void run(application.id, () =>
																	rejectVolunteerApplication(workspaceId, application.id, rejectReason),
																)
															}
														>
															{t("reject.confirm")}
														</button>
													</div>
												) : null}

												{/* 分配：选场次（draft/open）+ 备注；R15 副作用后端同事务 */}
												{assignTarget === application.id ? (
													<div className="rp-inline-form">
														<select
															className="rp-input"
															value={assignEventId}
															onChange={(event) => setAssignEventId(event.target.value)}
															aria-label={t("assign.eventLabel")}
														>
															<option value="">{t("assign.noEvent")}</option>
															{assignableEvents.map((event) => (
																<option key={event.id} value={event.id}>
																	{event.title}
																</option>
															))}
														</select>
														<input
															className="rp-input"
															value={assignNote}
															onChange={(event) => setAssignNote(event.target.value)}
															placeholder={t("assign.notePlaceholder")}
															aria-label={t("assign.noteLabel")}
														/>
														<button
															type="button"
															className="rp-action"
															disabled={busyId === application.id}
															onClick={() =>
																void run(application.id, () =>
																	assignVolunteerApplication(workspaceId, application.id, {
																		assignedEventId: assignEventId || null,
																		assignmentNote: assignNote || null,
																	}),
																)
															}
														>
															{t("assign.confirm")}
														</button>
													</div>
												) : null}

												{/* 取消：备注选填（与拒绝不同，无必填约束） */}
												{cancelTarget === application.id ? (
													<div className="rp-inline-form">
														<input
															className="rp-input"
															value={cancelNote}
															onChange={(event) => setCancelNote(event.target.value)}
															placeholder={t("cancel.notePlaceholder")}
															aria-label={t("cancel.noteLabel")}
														/>
														<button
															type="button"
															className="rp-action rp-action--danger"
															disabled={busyId === application.id}
															onClick={() =>
																void run(application.id, () =>
																	cancelVolunteerApplication(workspaceId, application.id, cancelNote || null),
																)
															}
														>
															{t("cancel.confirm")}
														</button>
													</div>
												) : null}

												{/* 详情：申请人档案元数据 + 简历下载（受保护端点） */}
												{details[application.id] !== undefined ? (
													<div className="rp-detail">
														{detail ? (
															<>
																<div>
																	{t("detail.fullName")}: {detail.resumeProfile?.fullName ?? t("detail.noResume")}
																</div>
																<div>
																	{t("detail.contactEmail")}: {detail.resumeProfile?.contactEmail ?? "—"}
																</div>
																{detail.resumeProfile?.fileName ? (
																	<a
																		className="rp-link"
																		href={`/api/recruitment/resumes/${detail.resumeProfile.id}`}
																		rel="noopener"
																	>
																		{t("detail.download", { name: detail.resumeProfile.fileName })}
																	</a>
																) : (
																	<span className="rp-muted">{t("detail.noFile")}</span>
																)}
															</>
														) : (
															<span className="rp-muted">{t("detail.loadFailed")}</span>
														)}
													</div>
												) : null}
											</li>
										);
									})}
								</ul>
							)}
						</section>
					</>
				)}
			</div>
		</WorkspaceShell>
	);
}
