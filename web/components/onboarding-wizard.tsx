"use client";

/**
 * 首公里接入向导（plan 2026-08-22 first-mile-onboarding U4，R4–R7；
 * U8 扩展：opencode 分支改走 OAuth 五步链）。
 *
 * 结构：开场（欢迎 + 为什么接入）+ 纵向 stepper，无硬门、进度不落库：
 * ① 选宿主：OpenClacky（默认推荐）/ OMP / opencode / DSH 单选
 *    （DSH 自 plan 2026-09-08 DSH parity U10 / R17 起正式开放，手动流：
 *    装插件家族 → ③ 签发 token → 面板粘贴，无自动连接等价物）；
 * ②③（OpenClacky / OMP / DSH）：安装与配置 + 生成连接 token。内容按宿主映射共享
 *    内容卡（@/components/agent-connect-sections，与原子页同一内容源，per R4）；
 *    「我已保存」确认即完成判定（两段式第一段，per Key Decision），进完成态
 *    （种子话术卡 + 出口：去概览 / 看活动）。完成态仅当次会话（组件 state）。
 *    OpenClacky 路径附「回 CGC 助手完成接入」指引段（OpenclackyAssistantHint）——
 *    缺它 token 只躺在剪贴板，无人触发扩展 /connect 写入 mcp.json，首联必失败。
 *    这几条分支的「②③ 常驻不卸载」不变：③ 签发面的一次性明文与在途签发请求是
 *    组件内 state，卸载/隐藏语义曾让服务端已签发 token 的明文面临丢失风险（P2）。
 *
 * opencode 分支（U8，plan 2026-09-15 opencode-desktop-host）：②–⑥ = OAuth 五步链
 *    （安装 → 模型获取 → 打开学习空间 → 授权连接 → 验证），与原子页共用同一批
 *    内容卡（步骤号由本向导供给：① 被宿主选择占用，故链为 ②–⑥）。OAuth 路径
 *    无明文，「②③ 常驻不卸载」在此退役；完成判定 = 第⑤步「授权连接」的授权完成
 *    （平台已有活跃授权，useOpencodeAuthPhase 的 active）——原「我已保存」两段式
 *    不再适用。手动配置卡进「开发者选项」折叠（默认收起）。
 *
 * readOnly（管理态「重新查看引导」回看）：stepper 内容在，但无签发面——
 * ③ 只给 MCP 页链接、opencode 分支不挂授权轮询（签发归 mcp tab）。
 *
 * 有任何 token 记录（含全撤销/过期）的用户在向导态保留管理态入口（链 mcp tab）；
 * hasTokenHistory 由调用方从 useOnboardingState().tokens 派生传入（同一数据源，
 * 本组件不再二次 fetch）。
 *
 * stepper 当前步（aria-current + 左侧品牌色条）：非 opencode 宿主停在 ③
 * （唯一可判定「待办」的动作步 = 签发）；opencode 停在 ⑤ 授权连接
 * （唯一带平台侧完成信号的动作步）。四种宿主一致无硬门。
 */

import { useState } from "react";
import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import {
	OpenclackyInstallCard,
	OpenclackyExtensionCard,
	OpenclackyAssistantHint,
	WriteConfigStepCard,
	ConfigureTokenStepCard,
	ConfigNotesStepCard,
	DshInstallCard,
	OpencodeInstallCard,
	OpencodeModelCard,
	OpencodeLearnSpaceCard,
	OpencodeAuthorizeCard,
	OpencodeVerifyCard,
	OpencodeDeveloperOptions,
} from "@/components/agent-connect-sections";
import McpTokenIssuePanel from "@/components/mcp-token-issue-panel";
import { useOpencodeAuthPhase } from "@/lib/use-opencode-auth-phase";

type WizardHost = "openclacky" | "omp" | "opencode" | "dsh";

export default function OnboardingWizard({
	slug,
	readOnly = false,
	hasTokenHistory = false,
}: {
	slug: string;
	/** 管理态回看：只读向导，无签发面 */
	readOnly?: boolean;
	/** 有任何 token 记录（含全撤销/过期）→ 向导态显示管理态入口；由调用方
	    从 useOnboardingState().tokens 派生（同一数据源，不二次 fetch） */
	hasTokenHistory?: boolean;
}) {
	const t = useTranslations("onboarding");
	const tConnect = useTranslations("agentConnect");
	const [host, setHost] = useState<WizardHost>("openclacky");
	const [tokenCompleted, setTokenCompleted] = useState(false);

	const opencodeBranch = host === "opencode";
	// opencode 的完成判定 = 平台已有活跃授权（第⑤步授权完成）；轮询只在
	// opencode 分支挂（其它宿主不轮询），只读回看不挂
	const { phase: opencodePhase, recheck: recheckOpencodeAuth } =
		useOpencodeAuthPhase(opencodeBranch && !readOnly);
	const opencodeAuthorized = opencodeBranch && !readOnly && opencodePhase === "active";
	const completed = tokenCompleted || opencodeAuthorized;

	// stepper 当前步：opencode 的动作步是 ⑤ 授权连接（其它宿主停在 ③ 签发）。
	// 高亮 = 左侧品牌色条；card 步（① 与 opencode 的 ②–⑥）自带内边距，只描边不补 padding
	const currentStep: number = opencodeBranch ? 5 : 3;
	const stepStyle = (n: number, card = false) =>
		currentStep === n
			? {
					borderLeft: "3px solid var(--brand)",
					...(card ? {} : { paddingLeft: 13 }),
				}
			: {};

	if (completed) {
		return (
			<div>
				<header className="ws-page-heading">
					<div>
						<h1>
							{opencodeAuthorized ? t("doneTitleOpencode") : t("doneTitle")}
						</h1>
						<p>
							{opencodeAuthorized ? t("doneDescOpencode") : t("doneDesc")}
						</p>
					</div>
				</header>
				<div className="connect-step-card" style={{ marginTop: 16 }}>
					<h2>{t("seedPhraseTitle")}</h2>
					<p className="connect-step-card__desc">
						{opencodeAuthorized ? t("seedPhraseDescOpencode") : t("seedPhraseDesc")}
					</p>
					<p>
						<code>{t("seedPhraseText")}</code>
					</p>
					<div className="connect-step-card__actions">
						<Link
							href={`/w/${slug}`}
							className="join-button join-button--primary"
						>
							{t("doneGoOverview")}
						</Link>
						<Link
							href={`/w/${slug}/events`}
							className="join-button join-button--outline"
						>
							{t("doneGoEvents")}
						</Link>
					</div>
				</div>
			</div>
		);
	}

	const HOST_CARDS: {
		key: WizardHost;
		name: string;
		badge?: string;
		desc: string;
	}[] = [
		{
			key: "openclacky",
			name: tConnect("titleOpenclacky"),
			badge: t("hostRecommended"),
			desc: t("hostOpenclackyDesc"),
		},
		{ key: "omp", name: tConnect("titleOmp"), desc: t("hostOmpDesc") },
		{
			key: "opencode",
			name: tConnect("titleOpencode"),
			desc: t("hostOpencodeDesc"),
		},
		{
			key: "dsh",
			name: t("hostDsh"),
			desc: t("hostDshDesc"),
		},
	];
	// ③ 签发面备注命名建议随已选宿主
	const hostName = HOST_CARDS.find((h) => h.key === host)?.name;

	return (
		<div>
			<header className="ws-page-heading">
				<div>
					<h1>{t("wizardTitle")}</h1>
					<p>{t("wizardWelcome")}</p>
				</div>
			</header>
			<p style={{ margin: "16px 0 0", color: "var(--ink-3)" }}>
				{opencodeBranch ? t("wizardWhyOpencode") : t("wizardWhy")}
			</p>

			<ol
				style={{
					listStyle: "none",
					margin: "16px 0 0",
					padding: 0,
					display: "grid",
					gap: 16,
				}}
			>
				<li
					className="connect-step-card"
					data-testid="onboarding-step-1"
					aria-current={currentStep === 1 ? "step" : undefined}
					style={stepStyle(1, true)}
				>
					<h2>{t("stepChooseHost")}</h2>
					<div
						role="radiogroup"
						aria-label={t("stepChooseHost")}
						style={{ display: "grid", gap: 8 }}
					>
						{HOST_CARDS.map((h) => (
							<label
								key={h.key}
								style={{
									display: "flex",
									gap: 8,
									alignItems: "flex-start",
									padding: "10px 12px",
									borderRadius: "var(--radius-small)",
									border: `1px solid ${host === h.key ? "var(--brand)" : "var(--line)"}`,
									cursor: "pointer",
								}}
							>
								<input
									type="radio"
									name="onboarding-host"
									checked={host === h.key}
									onChange={() => setHost(h.key)}
									style={{ marginTop: 4 }}
								/>
								<span style={{ display: "grid", gap: 4 }}>
									<span>
										<strong>{h.name}</strong>
										{h.badge && (
											<span
												className="l-badge l-badge-volunteer"
												style={{ marginLeft: 8 }}
											>
												{h.badge}
											</span>
										)}
									</span>
									<span
										className="connect-step-card__desc"
										style={{ margin: 0 }}
									>
										{h.desc}
									</span>
								</span>
							</label>
						))}
					</div>
				</li>

				{opencodeBranch ? (
					<>
						{/* opencode：OAuth 五步链（与原子页同一批内容卡；编号由本 ol 供给） */}
						<li
							data-testid="onboarding-step-2"
							aria-current={currentStep === 2 ? "step" : undefined}
							style={stepStyle(2, true)}
						>
							<OpencodeInstallCard stepNo="②" />
						</li>
						<li
							data-testid="onboarding-step-3"
							aria-current={currentStep === 3 ? "step" : undefined}
							style={stepStyle(3, true)}
						>
							<OpencodeModelCard stepNo="③" />
						</li>
						<li
							data-testid="onboarding-step-4"
							aria-current={currentStep === 4 ? "step" : undefined}
							style={stepStyle(4, true)}
						>
							<OpencodeLearnSpaceCard stepNo="④" />
						</li>
						<li
							data-testid="onboarding-step-5"
							aria-current={currentStep === 5 ? "step" : undefined}
							style={stepStyle(5, true)}
						>
							<OpencodeAuthorizeCard
								stepNo="⑤"
								phase={opencodePhase}
								onRecheck={readOnly ? undefined : recheckOpencodeAuth}
							/>
						</li>
						<li
							data-testid="onboarding-step-6"
							aria-current={currentStep === 6 ? "step" : undefined}
							style={stepStyle(6, true)}
						>
							<OpencodeVerifyCard stepNo="⑥" />
						</li>
					</>
				) : (
					<>
						<li
							data-testid="onboarding-step-2"
							aria-current={currentStep === 2 ? "step" : undefined}
							style={stepStyle(2)}
						>
							<h2>{t("stepInstall")}</h2>
							<div style={{ display: "grid", gap: 16, marginTop: 8 }}>
								{host === "openclacky" && (
									<>
										<OpenclackyInstallCard />
										<OpenclackyExtensionCard />
									</>
								)}
								{host === "omp" && (
									<>
										<WriteConfigStepCard variant="omp" />
										<ConfigureTokenStepCard variant="omp" />
										<ConfigNotesStepCard />
									</>
								)}
								{host === "dsh" && <DshInstallCard />}
							</div>
						</li>

						<li
							data-testid="onboarding-step-3"
							aria-current={currentStep === 3 ? "step" : undefined}
							style={stepStyle(3)}
						>
							<h2>{t("stepIssue")}</h2>
							<div style={{ marginTop: 8 }}>
								{readOnly ? (
									<div className="connect-step-card">
										<p className="connect-step-card__desc">
											{t.rich("reviewIssueHint", {
												link: (chunks) => (
													<Link
														href={`/w/${slug}/settings/integrations/agents/mcp`}
														className="connect-step-card__link"
													>
														{chunks}
													</Link>
												),
											})}
										</p>
									</div>
								) : host === "openclacky" ? (
									<div className="connect-step-card">
										<p className="connect-step-card__desc">{tConnect("oneClickConnectDesc")}</p>
										<div className="connect-step-card__actions">
											<a
												href="http://127.0.0.1:7070"
												target="_blank"
												rel="noreferrer"
												className="join-button join-button--primary"
											>
												{tConnect("openCgcOpenclacky")}
											</a>
										</div>
									</div>
								) : (
									<McpTokenIssuePanel
										onSaved={() => setTokenCompleted(true)}
										hostName={hostName}
									/>
								)}
								{/* OpenClacky 路径：签发只到剪贴板，须回 CGC 助手会话
								    触发扩展 /connect 才真正写入 mcp.json（P1 补回） */}
								{host === "openclacky" && <OpenclackyAssistantHint />}
							</div>
						</li>
					</>
				)}
			</ol>

			{/* opencode 手动配置（token 路径）收进开发者选项，默认收起 */}
			{opencodeBranch && (
				<div style={{ marginTop: 16 }}>
					<OpencodeDeveloperOptions slug={slug} />
				</div>
			)}

			{!readOnly && hasTokenHistory && (
				<p style={{ marginTop: 16 }}>
					<Link
						href={`/w/${slug}/settings/integrations/agents/mcp`}
						className="connect-step-card__link"
					>
						{t("manageTokensLink")}
					</Link>
				</p>
			)}
		</div>
	);
}
