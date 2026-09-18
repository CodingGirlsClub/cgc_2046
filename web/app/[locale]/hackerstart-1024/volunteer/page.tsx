"use client";

import { useCallback, useEffect, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import SiteHeader from "@/components/site-header";
import ResumeUpload, {
	readFileAsBase64,
	resumeContentType,
	type ResumeFileInfo,
} from "@/components/recruitment/resume-upload";
import { richTags } from "@/components/hackerstart-1024/pow";
import { rawArray } from "@/components/hackerstart-1024/raw-array";
import { useAuthed } from "@/lib/use-authed";
import { fetchCurrentProfile } from "@/lib/profile";
import { formatDeadline } from "@/lib/events";
import {
	VOLUNTEER_REVIEW_STAGES,
	createVolunteerApplication,
	fetchCampaignWorkspaceId,
	fetchCurrentRecruitmentCohort,
	fetchMyResumeProfile,
	fetchMyVolunteerApplications,
	upsertResumeProfile,
	uploadResumeFile,
	type RecruitmentCohort,
	type ResumeProfile,
	type VolunteerApplication,
	type VolunteerPosition,
} from "@/lib/graphql/recruitment";
import "@/components/hackerstart-1024/hackerstart-1024.css";

/**
 * 志愿者申请页（R10/R11/R18；Covers AE1、AE5、AE12 与 F2 前端侧）。
 *
 * 单页叙事结构照原型 `prototype/hackerstart-1024/host-apply`：hero → 当前批次
 * （**动态读 open 批次**，三态）→ 三职位（含职责/要求）→ featured 职位深读
 * （主理人三段 + 四项支持）→ 四段流程 → 分组 FAQ → 两步网申 → 我的申请。
 * 视觉 token 与组件惯例复用同页族 U6 的 `hackerstart-1024.css`（hs24- 前缀），
 * 表单控件用 Tailwind 任意值走同一套 PPT 色板（不引新样式表）。
 *
 * 数据面（U5/U2）：批次 / 简历档案 / 我的申请 / 提交申请 / 简历上传。
 * `workspaceId` 由当前用户成员列表按 slug 解析（`fetchCampaignWorkspaceId`）——
 * 招募活动全在 2046 台，而公开面没有匿名反查工作台 id 的口子，故本页的**读与写
 * 都在登录态内**：未登录访客看到的是完整叙事 + 登录引导（AE1，带回跳），
 * 登录后批次/表单/我的申请才出现。批次区三态（加载 / 失败+重试 / 无 open 批次）
 * 是登录态内的分支。
 *
 * PIPL（R11）：第 1 步的采集告知与显式勾选同意是上传与提交的硬前置（未勾选时
 * 选择入口禁用 + 提交被拦），链既有《隐私政策》/privacy。
 */

/** 本页路径（登录回跳 / 自引用锚点；locale 前缀由 i18n 导航补） */
const VOLUNTEER_PATH = "/hackerstart-1024/volunteer";

/** hero 声波柱（高度沿 2 的幂，与 U6 hero 同形） */
const WAVE_BARS = [8, 16, 24, 32, 48, 64, 48, 80, 64, 100, 80, 64, 48, 32, 24, 16];

type RawRole = {
	id: VolunteerPosition;
	t: string;
	en: string;
	featured?: boolean;
	duty: string[];
	reqs: string[];
};

type RawStep = { t: string; when: string; what: string; you: string; notice: string };
type RawFaqGroup = { g: string; items: Array<{ q: string; a: string }> };
type RawPair = { t: string; d: string };

/** 批次区渲染态（三态 + 匿名登录引导） */
type CohortView =
	| { kind: "checking" }
	| { kind: "anonymous" }
	| { kind: "loading" }
	| { kind: "failed" }
	| { kind: "empty" }
	| { kind: "open"; cohort: RecruitmentCohort };

export default function VolunteerApplyPage() {
	const t = useTranslations("volunteerApply");
	const tCommon = useTranslations("common");
	const errorsT = useTranslations("errors");
	const locale = useLocale();
	const { authed, confirmed } = useAuthed();

	// ── 数据面 ────────────────────────────────────────────────────────────────
	const [workspaceId, setWorkspaceId] = useState<string | null>(null);
	const [cohort, setCohort] = useState<RecruitmentCohort | null>(null);
	const [cohortSettled, setCohortSettled] = useState(false);
	const [cohortFailed, setCohortFailed] = useState(false);
	const [profile, setProfile] = useState<ResumeProfile | null>(null);
	const [apps, setApps] = useState<VolunteerApplication[] | null>(null);
	const [appsFailed, setAppsFailed] = useState(false);
	const [accountEmail, setAccountEmail] = useState("");
	const [nonce, setNonce] = useState(0);
	/** 提交成功（我的申请区顶部提示；段位展示在列表里） */
	const [justSubmitted, setJustSubmitted] = useState(false);

	// ── 第 1 步：简历档案 ─────────────────────────────────────────────────────
	const [fullName, setFullName] = useState("");
	const [contactEmail, setContactEmail] = useState("");
	const [weeklyHours, setWeeklyHours] = useState("");
	const [skills, setSkills] = useState<string[]>([]);
	const [consent, setConsent] = useState(false);
	const [step, setStep] = useState<1 | 2>(1);
	const [savingProfile, setSavingProfile] = useState(false);
	const [uploading, setUploading] = useState(false);
	const [uploadError, setUploadError] = useState<string | null>(null);
	const [formError, setFormError] = useState<string | null>(null);

	// ── 第 2 步：申请项 ───────────────────────────────────────────────────────
	const [position, setPosition] = useState<VolunteerPosition>("event_moderator");
	const [city, setCity] = useState("");
	const [heardAboutUs, setHeardAboutUs] = useState("");
	const [hasInternalReferrer, setHasInternalReferrer] = useState(false);
	const [message, setMessage] = useState("");
	const [submitting, setSubmitting] = useState(false);

	// 登录态确认后拉数据：workspaceId 先解析，再并行读批次/档案/我的申请
	useEffect(() => {
		if (!confirmed || !authed) return;
		let cancelled = false;

		void fetchCampaignWorkspaceId()
			.then((id) => {
				if (cancelled) return;
				setWorkspaceId(id);
				return Promise.all([
					fetchCurrentRecruitmentCohort(id)
						.then((value) => {
							if (cancelled) return;
							setCohort(value);
							setCohortSettled(true);
							setCohortFailed(false);
						})
						.catch(() => {
							if (cancelled) return;
							setCohortSettled(true);
							setCohortFailed(true);
						}),
					fetchMyResumeProfile(id)
						.then((value) => {
							if (cancelled || !value) return;
							setProfile(value);
							// 档案预填（已填过的名字/邮箱/投入/技能，跨批次复用）
							setFullName((current) => current || value.fullName);
							setContactEmail((current) => current || value.contactEmail);
							setWeeklyHours((current) =>
								current || (value.weeklyHours == null ? "" : String(value.weeklyHours)),
							);
							setSkills((current) => (current.length > 0 ? current : value.skills));
						})
						.catch(() => {
							/* 档案读失败不阻塞流程：按未建档处理，用户可重新填写 */
						}),
					fetchMyVolunteerApplications(id)
						.then((value) => {
							if (cancelled) return;
							setApps(value);
							setAppsFailed(false);
						})
						.catch(() => {
							if (cancelled) return;
							setApps([]);
							setAppsFailed(true);
						}),
					fetchCurrentProfile()
						.then((value) => {
							if (!cancelled) setAccountEmail(value.email ?? "");
						})
						.catch(() => {
							/* 账号资料读失败：联系邮箱回落为可编辑输入 */
						}),
				]);
			})
			.catch(() => {
				if (cancelled) return;
				setCohortSettled(true);
				setCohortFailed(true);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, nonce]);

	const retry = useCallback(() => {
		setCohortSettled(false);
		setCohortFailed(false);
		setAppsFailed(false);
		setApps(null);
		setNonce((n) => n + 1);
	}, []);

	/** 业务 code → 文案（未知 code 走调用方兜底，不直出英文原文） */
	const codeMessage = useCallback(
		(code: string | null | undefined, fallback: string) =>
			code && errorsT.has(code) ? errorsT(code) : fallback,
		[errorsT],
	);

	/** 有账号邮箱 → 预填且只读（手机号建号账号无邮箱 → 必填手输） */
	const emailLocked = accountEmail !== "";
	const effectiveEmail = emailLocked ? accountEmail : contactEmail;
	const skillsOptions = rawArray<{ value: string; label: string }>(t.raw("form.skillOptions"));
	const roles = rawArray<RawRole>(t.raw("roles.items"));
	const duty = rawArray<RawPair>(t.raw("deep.duty"));
	const supply = rawArray<RawPair>(t.raw("deep.supply"));
	const steps = rawArray<RawStep>(t.raw("flow.steps"));
	const faqGroups = rawArray<RawFaqGroup>(t.raw("faq.groups"));

	// 未登录访客的两步概览（原型 FORM_STEPS 展示；字段交互在登录后的表单里）
	const previewSteps = rawArray<{ n: number; t: string; fields: string[] }>(
		t.raw("form.previewSteps"),
	);

	const cohortView: CohortView = !confirmed
		? { kind: "checking" }
		: !authed
			? { kind: "anonymous" }
			: cohortFailed
				? { kind: "failed" }
				: !cohortSettled
					? { kind: "loading" }
					: cohort
						? { kind: "open", cohort }
						: { kind: "empty" };

	const openCohort = cohortView.kind === "open" ? cohortView.cohort : null;
	const cohortApplication =
		openCohort && apps
			? (apps.find((app) => app.cohortId === openCohort.id) ?? null)
			: null;
	const loginHref = `/login?next=${encodeURIComponent(VOLUNTEER_PATH)}`;

	// ── 第 1 步：上传（先建档再上传，U2 契约） ────────────────────────────────
	async function handleResumeFile(file: File) {
		setUploadError(null);
		if (!workspaceId) return;
		if (!consent) {
			setUploadError(t("form.consentRequired"));
			return;
		}
		const name = fullName.trim();
		const email = effectiveEmail.trim();
		if (!name || !email) {
			setUploadError(t("form.uploadNeedsProfile"));
			return;
		}
		setUploading(true);
		try {
			const created = await upsertResumeProfile(workspaceId, {
				fullName: name,
				contactEmail: email,
				weeklyHours: parseWeeklyHours(weeklyHours),
				skills,
			});
			if (!created.result) {
				setUploadError(codeMessage(created.errors[0]?.code, t("form.uploadFailed")));
				return;
			}
			const contentBase64 = await readFileAsBase64(file);
			const uploaded = await uploadResumeFile(workspaceId, {
				fileName: file.name,
				contentType: resumeContentType(file.name),
				contentBase64,
			});
			if (uploaded.result) {
				setProfile(uploaded.result);
			} else {
				setUploadError(codeMessage(uploaded.errors[0]?.code, t("form.uploadFailed")));
			}
		} catch {
			setUploadError(t("form.uploadFailed"));
		} finally {
			setUploading(false);
		}
	}

	// ── 第 1 步 → 第 2 步 ────────────────────────────────────────────────────
	async function goToStep2() {
		setFormError(null);
		if (!consent) {
			setFormError(t("form.consentRequired"));
			return;
		}
		if (!fullName.trim() || !effectiveEmail.trim()) {
			setFormError(t("form.profileIncomplete"));
			return;
		}
		if (!profile?.fileName) {
			setFormError(t("form.fileRequired"));
			return;
		}
		if (!workspaceId) return;
		setSavingProfile(true);
		try {
			const saved = await upsertResumeProfile(workspaceId, {
				fullName: fullName.trim(),
				contactEmail: effectiveEmail.trim(),
				weeklyHours: parseWeeklyHours(weeklyHours),
				skills,
			});
			if (saved.result) {
				setProfile(saved.result);
				setStep(2);
			} else {
				setFormError(codeMessage(saved.errors[0]?.code, t("form.submitFailed")));
			}
		} catch {
			setFormError(t("form.submitFailed"));
		} finally {
			setSavingProfile(false);
		}
	}

	// ── 第 2 步：提交申请 ────────────────────────────────────────────────────
	async function submitApplication(event: React.FormEvent) {
		event.preventDefault();
		if (!workspaceId || !openCohort) return;
		setFormError(null);
		setSubmitting(true);
		try {
			const payload = await createVolunteerApplication(workspaceId, {
				cohortId: openCohort.id,
				position,
				city: city.trim() || null,
				heardAboutUs: heardAboutUs.trim() || null,
				hasInternalReferrer,
				message: message.trim() || null,
			});
			if (payload.result) {
				setJustSubmitted(true);
				try {
					const refreshed = await fetchMyVolunteerApplications(workspaceId);
					setApps(refreshed);
					setAppsFailed(false);
				} catch {
					/* 刷新失败不掩盖提交成功：我的申请区自带失败+重试出口 */
					setAppsFailed(true);
				}
				// 视线引导到「我的申请」（段位展示）；无布局引擎的环境静默跳过
				const anchor = document.getElementById("va-my-apps");
				if (anchor && typeof anchor.scrollIntoView === "function") {
					anchor.scrollIntoView({ behavior: "smooth", block: "start" });
				}
			} else {
				setFormError(codeMessage(payload.errors[0]?.code, t("form.submitFailed")));
			}
		} catch {
			setFormError(t("form.submitFailed"));
		} finally {
			setSubmitting(false);
		}
	}

	const profileFileInfo: ResumeFileInfo | null = profile
		? {
				fileName: profile.fileName,
				fileSize: profile.fileSize,
				uploadedAt: profile.uploadedAt,
			}
		: null;

	return (
		<main className="hs24-root">
			<SiteHeader />

			{/* ① Hero（照原型：十周年封面 + 两句 CTA） */}
			<div className="hs24-hero-wrap">
				<div className="hs24-container">
					<section className="hs24-hero" aria-labelledby="va-hero-title">
						<p className="hs24-hero__eyebrow">{t("hero.eyebrow")}</p>
						<h1 className="hs24-hero__title" id="va-hero-title">
							{t.rich("hero.title", richTags)}
						</h1>
						<p className="hs24-hero__sub">{t("hero.sub")}</p>
						<p className="hs24-hero__nums">
							{rawArray<string>(t.raw("hero.nums")).map((item) => (
								<span key={item}>{item}</span>
							))}
						</p>
						<div className="hs24-hero__cta">
							<Link href="#va-apply" className="hs24-cta--white">
								{t("hero.ctaApply")}
							</Link>
							<Link href="#va-roles" className="hs24-cta--outline">
								{t("hero.ctaRoles")}
							</Link>
						</div>
						<div className="hs24-wave" aria-hidden="true">
							{WAVE_BARS.map((height, index) => (
								<i key={index} style={{ height: `${height}%` }} />
							))}
						</div>
					</section>
				</div>
			</div>

			{/* ② 当前批次（R10：动态读 open 批次 + 三态；AE12 空态收入口） */}
			<section className="hs24-section" id="va-cohort" aria-labelledby="va-cohort-title">
				<div className="hs24-container">
					<div className="hs24-badge-row">
						<span className="hs24-badge">{t("cohort.badge")}</span>
						<span className="hs24-badge-label">{t("cohort.label")}</span>
					</div>
					<h2 className="hs24-title" id="va-cohort-title">
						{t.rich("cohort.title", richTags)}
					</h2>
					<CohortCard
						view={cohortView}
						loginHref={loginHref}
						deadline={
							openCohort
								? formatDeadline(openCohort.applyDeadlineAt, tCommon("timeTbd"), locale)
								: ""
						}
						period={
							openCohort
								? `${formatDeadline(openCohort.startsAt, tCommon("timeTbd"), locale)} – ${formatDeadline(openCohort.endsAt, tCommon("timeTbd"), locale)}`
								: ""
						}
					/>
					<p className="hs24-lead hs24-lead--muted mt-[18px]">{t("cohort.note")}</p>
				</div>
			</section>

			{/* ③ 三职位（职责 + 职位要求；同批一职位纪律在胶囊条） */}
			<section className="hs24-section" id="va-roles" aria-labelledby="va-roles-title">
				<div className="hs24-container">
					<div className="hs24-badge-row">
						<span className="hs24-badge">{t("roles.badge")}</span>
						<span className="hs24-badge-label">{t("roles.label")}</span>
					</div>
					<h2 className="hs24-title" id="va-roles-title">
						{t.rich("roles.title", richTags)}
					</h2>
					<div className="hs24-cap3" role="radiogroup" aria-label={t("roles.tablistLabel")}>
						{roles.map((role, index) => (
							<div
								key={role.id}
								role="radio"
								aria-checked={position === role.id}
								tabIndex={0}
								onClick={() => setPosition(role.id)}
								onKeyDown={(event) => {
									if (event.key === "Enter" || event.key === " ") {
										event.preventDefault();
										setPosition(role.id);
									}
								}}
								className={`hs24-tile hs24-tile--selectable${position === role.id ? " hs24-tile--selected" : ""}`}
							>
								<div className="hs24-tile__t">
									<span className="hs24-tile__n">{index + 1}</span>
									{role.t}
									{role.featured ? (
										<span className="hs24-tile__badge">{t("roles.featured")}</span>
									) : null}
									<small>{role.en}</small>
								</div>
								<div className="hs24-tile__d">
									<b>{t("roles.dutyTitle")}</b>
									<ul className="mt-[6px] mb-[10px] pl-[18px] list-disc">
										{rawArray<string>(role.duty).map((item) => (
											<li key={item}>{item}</li>
										))}
									</ul>
									<b>{t("roles.reqTitle")}</b>
									<ul className="mt-[6px] pl-[18px] list-disc">
										{rawArray<string>(role.reqs).map((item) => (
											<li key={item}>{item}</li>
										))}
									</ul>
								</div>
							</div>
						))}
					</div>
					<div className="hs24-pill">
						{rawArray<string>(t.raw("roles.pill")).map((item) => (
							<span key={item}>{item}</span>
						))}
					</div>
				</div>
			</section>

			{/* ④ featured 职位深读（主理人：职责三段 + 四项支持） */}
			<section className="hs24-section" aria-labelledby="va-deep-title">
				<div className="hs24-container">
					<div className="hs24-badge-row">
						<span className="hs24-badge">{t("deep.badge")}</span>
						<span className="hs24-badge-label">{t("deep.label")}</span>
					</div>
					<blockquote className="hs24-epi">
						{t("deep.quote")}
						<em>{t("deep.quoteBy")}</em>
					</blockquote>
					<h2 className="hs24-title" id="va-deep-title">
						{t.rich("deep.title", richTags)}
					</h2>
					<div className="hs24-cap3">
						{duty.map((item, index) => (
							<div key={item.t} className="hs24-tile">
								<div className="hs24-tile__t">
									<span className="hs24-tile__n">{index + 1}</span>
									{item.t}
								</div>
								<div className="hs24-tile__d">{item.d}</div>
							</div>
						))}
					</div>
					<div className="hs24-tiles">
						{supply.map((item, index) => (
							<div key={item.t} className="hs24-tile">
								<div className="hs24-tile__t">
									<span className="hs24-tile__n">{index + 1}</span>
									{item.t}
								</div>
								<div className="hs24-tile__d">{item.d}</div>
							</div>
						))}
					</div>
				</div>
			</section>

			{/* ⑤ 四段流程（网申 → 面试 → 训练营 → 项目分配；每段双通道通知） */}
			<section className="hs24-section" aria-labelledby="va-flow-title">
				<div className="hs24-container">
					<div className="hs24-badge-row">
						<span className="hs24-badge">{t("flow.badge")}</span>
						<span className="hs24-badge-label">{t("flow.label")}</span>
					</div>
					<h2 className="hs24-title" id="va-flow-title">
						{t.rich("flow.title", richTags)}
					</h2>
					<div className="hs24-ladder">
						{steps.map((item, index) => (
							<div key={item.t} className="hs24-ladder__step">
								<span className="hs24-ladder__n">{String(index + 1).padStart(2, "0")}</span>
								<span className="flex-1">
									<span className="hs24-ladder__t block">
										{item.t}
										<small className="ml-[6px] text-[#b9b3c2] font-normal">
											· {item.when}
										</small>
									</span>
									<span className="hs24-ladder__d block">{item.what}</span>
									<span className="hs24-ladder__d block text-[#b0406b]">{item.you}</span>
									<span className="hs24-ladder__d block text-[#2fa69d]">
										{item.notice}
									</span>
								</span>
							</div>
						))}
					</div>
					<p className="hs24-ladder__cap">{t("flow.cap")}</p>
				</div>
			</section>

			{/* ⑥ 分组志愿者 FAQ */}
			<section className="hs24-section" aria-labelledby="va-faq-title">
				<div className="hs24-container">
					<div className="hs24-badge-row">
						<span className="hs24-badge">{t("faq.badge")}</span>
						<span className="hs24-badge-label">{t("faq.label")}</span>
					</div>
					<h2 className="hs24-title" id="va-faq-title">
						{t.rich("faq.title", richTags)}
					</h2>
					{faqGroups.map((group) => (
						<div key={group.g}>
							<p className="hs24-sub">{group.g}</p>
							<div className="hs24-faq">
								{rawArray<{ q: string; a: string }>(group.items).map((item) => (
									<details key={item.q}>
										<summary>{item.q}</summary>
										<p>{item.a}</p>
									</details>
								))}
							</div>
						</div>
					))}
				</div>
			</section>

			{/* ⑦ 两步网申（AE1 登录引导 / AE2 本批已申请 / AE5 跳过重传） */}
			<section className="hs24-section" id="va-apply" aria-labelledby="va-apply-title">
				<div className="hs24-container">
					<div className="hs24-badge-row">
						<span className="hs24-badge hs24-badge--mint">{t("form.badge")}</span>
						<span className="hs24-badge-label">{t("form.label")}</span>
					</div>
					<h2 className="hs24-title" id="va-apply-title">
						{t.rich("form.title", richTags)}
					</h2>
					<p className="hs24-lead hs24-lead--muted">{t("form.lead")}</p>

					{cohortView.kind === "anonymous" || cohortView.kind === "checking" ? (
						<div className="hs24-tile mt-[26px] max-w-[720px]">
							<p className="text-[15px] text-[#2b2b33]">
								{cohortView.kind === "checking" ? t("form.checking") : t("form.loginFirst")}
							</p>
							<p className="mt-[8px] text-[13px] text-[#857f8f]">{t("form.anonCohortHint")}</p>
							{cohortView.kind === "anonymous" ? (
								<div className="mt-[14px] flex flex-wrap items-center gap-4">
									<Link href={loginHref} className="hs24-cta--rose hs24-cta--flush">
										{t("form.login")}
									</Link>
									<Link href="/register" className="text-[14px] text-[#b0406b] underline">
										{t("form.register")}
									</Link>
								</div>
							) : null}
						</div>
					) : cohortView.kind === "failed" ? (
						<div className="hs24-tile mt-[26px] max-w-[720px]" role="alert">
							<p className="text-[15px] text-[#2b2b33]">{t("cohort.loadFailed")}</p>
							<button
								type="button"
								onClick={retry}
								className="mt-[14px] rounded-full border-2 border-[#c9497d] px-5 py-2 text-[15px] font-bold text-[#b0406b]"
							>
								{tCommon("retry")}
							</button>
						</div>
					) : cohortView.kind === "empty" || cohortView.kind === "loading" ? (
						<div className="hs24-tile mt-[26px] max-w-[720px]">
							{cohortView.kind === "loading" ? (
								<p className="text-[15px] text-[#857f8f]">{t("cohort.loading")}</p>
							) : (
								<>
									<p className="text-[15px] font-bold text-[#2b2b33]">
										{t("cohort.emptyTitle")}
									</p>
									<p className="mt-[6px] text-[14px] text-[#7a7396]">
										{t("cohort.emptyDesc")}
									</p>
								</>
							)}
						</div>
					) : cohortApplication ? (
						<div className="hs24-tile mt-[26px] max-w-[720px]" role="status">
							<p className="text-[15px] font-bold text-[#2b2b33]">{t("form.appliedTitle")}</p>
							<p className="mt-[6px] text-[14px] text-[#7a7396]">{t("form.appliedDesc")}</p>
							<ApplicationStatusCard
								application={cohortApplication}
								className="mt-[16px] border-[1.5px] border-[#e8e4ec] rounded-[14px] p-[16px]"
							/>
						</div>
					) : !authed ? (
						<>
							{/* 未登录：原型同款两步概览（说明性内容 + 登录 CTA；字段交互需登录） */}
							<div className="hs24-cap3 mt-[26px]">
								{previewSteps.map((step) => (
									<div key={step.t} className="hs24-tile">
										<div className="hs24-tile__t">
											<span className="hs24-tile__n">{step.n}</span>
											{step.t}
										</div>
										<ul className="hs24-tile__d mt-[8px] flex list-disc flex-col gap-[6px] pl-[18px]">
											{step.fields.map((field) => (
												<li key={field}>{field}</li>
											))}
										</ul>
									</div>
								))}
							</div>
							<div className="hs24-tile mt-[18px] max-w-[720px]">
								<p className="text-[15px] font-bold text-[#2b2b33]">{t("form.loginFirst")}</p>
								<div className="hs24-cta-row mt-[14px]">
									<Link href={loginHref} className="hs24-cta--rose hs24-cta--flush">
										{t("form.login")}
									</Link>
									<Link href="/register" className="hs24-cta--rose hs24-cta--ghost hs24-cta--flush">
										{t("form.register")}
									</Link>
								</div>
							</div>
						</>
					) : (
						<form onSubmit={submitApplication} className="mt-[26px] max-w-[720px]">
							<ol className="hs24-pill mt-0">
								<li>
									{step === 1 ? t("form.stepNow", { n: 1 }) : t("form.stepDone", { n: 1 })}
								</li>
								<li aria-hidden="true">→</li>
								<li>{step === 2 ? t("form.stepNow", { n: 2 }) : t("form.stepTodo", { n: 2 })}</li>
							</ol>

							{step === 1 ? (
								<div className="mt-[22px] flex flex-col gap-5">
									<h3 className="text-[19px] font-extrabold text-[#2b2b33]">
										{t("form.step1Title")}
									</h3>
									{profile?.fileName ? (
										<p className="text-[13.5px] text-[#2fa69d]">{t("form.profileReused")}</p>
									) : null}

									<label className="flex flex-col gap-1 text-[14px] font-medium text-[#2b2b33]">
										{t("form.fullName")}
										<input
											value={fullName}
											onChange={(event) => setFullName(event.target.value)}
											className={INPUT_CLASS}
										/>
									</label>

									<label className="flex flex-col gap-1 text-[14px] font-medium text-[#2b2b33]">
										{t("form.contactEmail")}
										<input
											type="email"
											value={effectiveEmail}
											readOnly={emailLocked}
											onChange={(event) => setContactEmail(event.target.value)}
											className={`${INPUT_CLASS}${emailLocked ? " bg-[#f7f4f8] text-[#857f8f]" : ""}`}
										/>
									</label>
									{emailLocked ? (
										<p className="-mt-3 text-[12.5px] text-[#857f8f]">
											{t("form.contactEmailFromAccount")}
										</p>
									) : null}

									<label className="flex flex-col gap-1 text-[14px] font-medium text-[#2b2b33]">
										{t("form.weeklyHours")}
										<input
											type="number"
											min={1}
											max={168}
											value={weeklyHours}
											onChange={(event) => setWeeklyHours(event.target.value)}
											className={INPUT_CLASS}
										/>
									</label>

									<fieldset className="flex flex-col gap-2">
										<legend className="mb-[6px] text-[14px] font-medium text-[#2b2b33]">
											{t("form.skills")}
										</legend>
										<div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
											{skillsOptions.map((option) => (
												<label
													key={option.value}
													className="flex items-center gap-2 text-[14px] text-[#2b2b33]"
												>
													<input
														type="checkbox"
														checked={skills.includes(option.value)}
														onChange={(event) =>
															setSkills((current) =>
																event.target.checked
																	? [...current, option.value]
																	: current.filter((item) => item !== option.value),
															)
														}
													/>
													{option.label}
												</label>
											))}
										</div>
									</fieldset>

									<fieldset className="flex flex-col gap-2">
										<legend className="mb-[6px] text-[14px] font-medium text-[#2b2b33]">
											{t("form.resume")}
										</legend>
										<ResumeUpload
											disabled={!consent}
											busy={uploading}
											profile={profileFileInfo}
											error={uploadError}
											onSelect={handleResumeFile}
										/>
									</fieldset>

									{/* 采集告知 + 显式勾选同意（PIPL；未勾选不得上传与提交） */}
									<label
										htmlFor="va-consent"
										className="flex items-start gap-3 rounded-[14px] bg-[#f7f4f8] p-[16px] text-[13.5px] leading-[1.7] text-[#2b2b33]"
									>
										<input
											id="va-consent"
											type="checkbox"
											checked={consent}
											onChange={(event) => setConsent(event.target.checked)}
											className="mt-[3px] flex-none"
										/>
										<span>
											{t("form.consentPrefix")}
											<Link href="/privacy" className="text-[#b0406b] underline">
												{t("form.consentLink")}
											</Link>
											{t("form.consentSuffix")}
										</span>
									</label>

									{formError ? (
										<p className="text-[13.5px] text-[#b0406b]" role="alert">
											{formError}
										</p>
									) : null}

									<div>
										<button
											type="button"
											onClick={goToStep2}
											disabled={savingProfile}
											className="rounded-full bg-[#c9497d] px-7 py-[13px] text-[16px] font-bold text-white disabled:opacity-60"
										>
											{savingProfile ? t("form.saving") : t("form.next")}
										</button>
									</div>
								</div>
							) : (
								<div className="mt-[22px] flex flex-col gap-5">
									<h3 className="text-[19px] font-extrabold text-[#2b2b33]">
										{t("form.step2Title")}
									</h3>

									<p className="text-[14px] text-[#2b2b33]">
										{t("form.cohortLine", { name: openCohort ? openCohort.name : "" })}
									</p>

									<fieldset className="flex flex-col gap-2">
										<legend className="mb-[6px] text-[14px] font-medium text-[#2b2b33]">
											{t("form.position")}
										</legend>
										{roles.map((role) => (
											<label
												key={role.id}
												className="flex items-center gap-2 text-[14px] text-[#2b2b33]"
											>
												<input
													type="radio"
													name="va-position"
													value={role.id}
													checked={position === role.id}
													onChange={() => setPosition(role.id)}
												/>
												{role.t}
											</label>
										))}
										<p className="text-[12.5px] text-[#857f8f]">{t("form.positionNote")}</p>
									</fieldset>

									<label className="flex flex-col gap-1 text-[14px] font-medium text-[#2b2b33]">
										{t("form.city")}
										<input
											value={city}
											onChange={(event) => setCity(event.target.value)}
											className={INPUT_CLASS}
										/>
									</label>
									<p className="-mt-3 text-[12.5px] text-[#857f8f]">{t("form.cityHint")}</p>

									<label className="flex flex-col gap-1 text-[14px] font-medium text-[#2b2b33]">
										{t("form.heardAboutUs")}
										<input
											value={heardAboutUs}
											onChange={(event) => setHeardAboutUs(event.target.value)}
											className={INPUT_CLASS}
										/>
									</label>

									<label className="flex items-center gap-2 text-[14px] text-[#2b2b33]">
										<input
											type="checkbox"
											checked={hasInternalReferrer}
											onChange={(event) => setHasInternalReferrer(event.target.checked)}
										/>
										{t("form.hasReferrer")}
									</label>

									<label className="flex flex-col gap-1 text-[14px] font-medium text-[#2b2b33]">
										{t("form.message")}
										<textarea
											rows={4}
											value={message}
											onChange={(event) => setMessage(event.target.value)}
											className={INPUT_CLASS}
										/>
									</label>

									{formError ? (
										<p className="text-[13.5px] text-[#b0406b]" role="alert">
											{formError}
										</p>
									) : null}

									{/* R21：订阅消息授权主引导在小程序端，web 侧只留提示位 */}
									<p className="text-[12.5px] text-[#857f8f]">{t("form.noticeHint")}</p>
									<p className="text-[12.5px] text-[#b9b3c2]">{t("form.privacyNote")}</p>

									<div className="flex flex-wrap items-center gap-4">
										<button
											type="submit"
											disabled={submitting}
											className="rounded-full bg-[#c9497d] px-7 py-[13px] text-[16px] font-bold text-white disabled:opacity-60"
										>
											{submitting ? t("form.submitting") : t("form.submit")}
										</button>
										<button
											type="button"
											onClick={() => {
												setFormError(null);
												setStep(1);
											}}
											className="text-[14px] text-[#b0406b] underline"
										>
											{t("form.back")}
										</button>
									</div>
								</div>
							)}
						</form>
					)}
				</div>
			</section>

			{/* ⑧ 我的申请（未登录 → 中性四段预览；登录后展示真实段位） */}
			{confirmed ? (
				<section className="hs24-section" id="va-my-apps" aria-labelledby="va-my-apps-title">
					<div className="hs24-container">
						<div className="hs24-badge-row">
							<span className="hs24-badge">{t("myApps.badge")}</span>
							<span className="hs24-badge-label">{t("myApps.label")}</span>
						</div>
						<h2 className="hs24-title" id="va-my-apps-title">
							{t.rich("myApps.title", richTags)}
						</h2>

						{justSubmitted ? (
							<p className="mt-[18px] text-[15px] font-bold text-[#2fa69d]" role="status">
								{t("myApps.submitted")}
							</p>
						) : null}

						{!authed ? (
							<div className="mt-[22px]">
								<p className="text-[14px] text-[#857f8f]">{t("myApps.anonHint")}</p>
								<ol className="mt-[18px] grid grid-cols-1 gap-2 sm:grid-cols-4">
									{VOLUNTEER_REVIEW_STAGES.map((stage) => (
										<li key={stage} className="flex items-center gap-2 text-[13.5px]">
											<span
												aria-hidden="true"
												className="inline-block h-[10px] w-[10px] flex-none rounded-full bg-[#e8e4ec]"
											/>
											<span className="text-[#b9b3c2]">{t(`stageLabels.${stage}`)}</span>
										</li>
									))}
								</ol>
							</div>
						) : appsFailed ? (
							<div className="hs24-tile mt-[22px] max-w-[720px]" role="alert">
								<p className="text-[15px] text-[#2b2b33]">{t("myApps.loadFailed")}</p>
								<button
									type="button"
									onClick={retry}
									className="mt-[14px] rounded-full border-2 border-[#c9497d] px-5 py-2 text-[15px] font-bold text-[#b0406b]"
								>
									{tCommon("retry")}
								</button>
							</div>
						) : apps === null ? (
							<p className="mt-[22px] text-[14px] text-[#857f8f]">{t("myApps.loading")}</p>
						) : apps.length === 0 ? (
							<p className="mt-[22px] text-[14px] text-[#857f8f]">{t("myApps.empty")}</p>
						) : (
							<ul className="mt-[22px] flex max-w-[720px] flex-col gap-3">
								{apps.map((application) => (
									<li key={application.id}>
										<ApplicationStatusCard
											application={application}
											className="border-[1.5px] border-[#e8e4ec] rounded-[16px] p-[20px]"
										/>
									</li>
								))}
							</ul>
						)}
					</div>
				</section>
			) : null}

			{/* ⑨ footer（回宣传页 + hashtag；原型同形） */}
			<footer className="hs24-footer">
				<div className="hs24-container hs24-footer__inner">
					<span>
						{t("footer.org")}
						<br />
						<Link href="/hackerstart-1024">{t("footer.back")}</Link>
					</span>
					<b>{t("footer.hashtag")}</b>
				</div>
			</footer>
		</main>
	);
}

/** 表单控件统一外观（PPT 色板任意值；不引新样式表） */
const INPUT_CLASS =
	"w-full rounded-[12px] border-[1.5px] border-[#e8e4ec] bg-white px-3 py-2 text-[15px] text-[#2b2b33] outline-none focus:border-[#c9497d]";

/** 周投入小时数：空 → null（后端选填），非法 → null */
function parseWeeklyHours(value: string): number | null {
	const parsed = Number.parseInt(value, 10);
	return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

/** 批次卡（三态 + 匿名登录引导；有 open 批次时带申请入口） */
function CohortCard({
	view,
	loginHref,
	deadline,
	period,
}: {
	view: CohortView;
	loginHref: string;
	deadline: string;
	period: string;
}) {
	const t = useTranslations("volunteerApply");

	if (view.kind === "checking" || view.kind === "loading") {
		return (
			<div className="hs24-tile hs24-cohort" aria-busy="true">
				<p className="text-[14px] text-[#857f8f]">{t("cohort.loading")}</p>
			</div>
		);
	}

	if (view.kind === "failed") {
		return (
			<div className="hs24-tile hs24-cohort" role="alert">
				<p className="text-[14px] text-[#2b2b33]">{t("cohort.loadFailed")}</p>
				<span className="hs24-cohort__note">{t("cohort.retryHint")}</span>
			</div>
		);
	}

	if (view.kind === "anonymous") {
		return (
			<div className="hs24-tile hs24-cohort">
				<p className="text-[14px] text-[#2b2b33]">{t("cohort.loginRequired")}</p>
				<span className="hs24-cohort__spacer" />
				<Link href={loginHref} className="hs24-cta--rose hs24-cta--flush">
					{t("form.login")}
				</Link>
			</div>
		);
	}

	if (view.kind === "empty") {
		return (
			<div className="hs24-tile hs24-cohort">
				<span className="hs24-cohort__status">{t("cohort.emptyBadge")}</span>
				<span className="hs24-cohort__name">{t("cohort.emptyTitle")}</span>
				<span className="hs24-cohort__note">{t("cohort.emptyDesc")}</span>
			</div>
		);
	}

	return (
		<div className="hs24-tile hs24-cohort">
			<span className="hs24-cohort__status">{t("cohort.openBadge")}</span>
			<span className="hs24-cohort__name">{view.cohort.name}</span>
			<span className="hs24-cohort__note">
				{t("cohort.deadline", { time: deadline })}
			</span>
			<span className="hs24-cohort__note">
				{t("cohort.period", { time: period })}
			</span>
			<span className="hs24-cohort__spacer" />
			<Link href="#va-apply" className="hs24-cta--rose hs24-cta--flush">
				{t("cohort.cta")}
			</Link>
		</div>
	);
}

/** 申请条目：段位胶囊 + 四段进度条 + 拒绝原因 / 分配备注 */
function ApplicationStatusCard({
	application,
	className,
}: {
	application: VolunteerApplication;
	className?: string;
}) {
	const t = useTranslations("volunteerApply");
	const tCommon = useTranslations("common");
	const locale = useLocale();
	const stageIndex = VOLUNTEER_REVIEW_STAGES.indexOf(
		application.status as (typeof VOLUNTEER_REVIEW_STAGES)[number],
	);
	const terminated = stageIndex < 0;

	return (
		<div className={className}>
			<div className="flex flex-wrap items-center gap-3">
				<span className="hs24-cohort__status">{t(`statusLabels.${application.status}`)}</span>
				<span className="font-bold text-[15px] text-[#2b2b33]">
					{t(`positions.${application.position}`)}
				</span>
				{application.city ? (
					<span className="text-[13.5px] text-[#857f8f]">
						{t("myApps.city", { city: application.city })}
					</span>
				) : null}
			</div>

			{/* 段位条：assigned 为终态；rejected/canceled 走终止态文案 */}
			{terminated ? (
				<p className="mt-[10px] text-[13.5px] text-[#b0406b]">
					{application.status === "rejected"
						? t("myApps.rejected")
						: t("myApps.canceled")}
				</p>
			) : (
				<ol className="mt-[14px] grid grid-cols-1 gap-2 sm:grid-cols-4">
					{VOLUNTEER_REVIEW_STAGES.map((stage, index) => (
						<li key={stage} className="flex items-center gap-2 text-[13.5px]">
							<span
								aria-hidden="true"
								className={`inline-block h-[10px] w-[10px] flex-none rounded-full ${
									index <= stageIndex ? "bg-[#c9497d]" : "bg-[#e8e4ec]"
								}`}
							/>
							<span className={index <= stageIndex ? "text-[#2b2b33]" : "text-[#b9b3c2]"}>
								{t(`stageLabels.${stage}`)}
							</span>
						</li>
					))}
				</ol>
			)}

			{application.rejectionReason ? (
				<p className="mt-[10px] text-[13.5px] text-[#7a7396]">
					{t("myApps.rejectionReason", { reason: application.rejectionReason })}
				</p>
			) : null}
			{application.assignmentNote ? (
				<p className="mt-[10px] text-[13.5px] text-[#7a7396]">
					{t("myApps.assignmentNote", { note: application.assignmentNote })}
				</p>
			) : null}
			{application.assignedAt ? (
				<p className="mt-[6px] text-[12.5px] text-[#b9b3c2]">
					{t("myApps.assignedAt", {
						time: formatDeadline(application.assignedAt, tCommon("timeTbd"), locale),
					})}
				</p>
			) : null}
		</div>
	);
}
