"use client";

/**
 * 首公里接入向导（plan 2026-08-22 first-mile-onboarding U4，R4–R7）。
 *
 * 结构：开场（欢迎 + 为什么接入）+ 纵向 stepper 三步，无硬门、进度不落库：
 * ① 选宿主：OpenClacky（默认推荐）/ OMP / opencode 单选 + DSH「即将推出」占位卡
 *    （选中 DSH 只展示说明，②③ 不展开，AE3）；
 * ② 安装与配置：内容按宿主映射共享内容卡（@/components/agent-connect-sections，
 *    与原子页同一内容源，per R4）；
 * ③ 生成连接 token：内嵌 McpTokenIssuePanel（与 mcp 页同一签出面），
 *    「我已保存」确认即完成判定（两段式第一段，per Key Decision），进完成态
 *    （种子话术卡 + 出口：去概览 / 看活动）。完成态仅当次会话（组件 state）。
 *
 * readOnly（管理态「重新查看引导」回看）：stepper 内容在，但无签发面——
 * ③ 只给 MCP 页链接（签发归 mcp tab）。
 *
 * 有任何 token 记录（含全撤销/过期）的用户在向导态保留管理态入口（链 mcp tab）；
 * hasTokenHistory 由调用方从 useOnboardingState().tokens 派生传入（同一数据源，
 * 本组件不再二次 fetch）。
 *
 * stepper 当前步（aria-current + 左侧品牌色条）：①②无完成信号可追踪
 * （宿主默认已选、安装为自助阅读），唯一可判定「待办」的动作步是 ③ 签发；
 * 选中 DSH 时 ②③ 不展开，当前步停在 ①。
 */

import { useState } from "react";
import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import {
	OpenclackyInstallCard,
	OpenclackyExtensionCard,
	WriteConfigStepCard,
	ConfigureTokenStepCard,
	ConfigNotesStepCard,
} from "@/components/agent-connect-sections";
import McpTokenIssuePanel from "@/components/mcp-token-issue-panel";

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
	const [completed, setCompleted] = useState(false);

	// stepper 当前步：选中 DSH（②③ 不展开）停在 ①；其余情况 ③ 是唯一
	// 带完成信号的动作步（签发 + 「我已保存」），①② 为自助阅读。
	// 高亮 = 左侧品牌色条；card 步（①）自带内边距，只描边不补 padding
	// 显式 number 标注：阻止 TS 在 host!=="dsh" 分支内把 currentStep 收窄成 3
	// （② 永非当前步是今天的语义，类型上保留 2 的合法位）
	const currentStep: number = host === "dsh" ? 1 : 3;
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
						<h1>{t("doneTitle")}</h1>
						<p>{t("doneDesc")}</p>
					</div>
				</header>
				<div className="connect-step-card" style={{ marginTop: 16 }}>
					<h2>{t("seedPhraseTitle")}</h2>
					<p className="connect-step-card__desc">{t("seedPhraseDesc")}</p>
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
			badge: t("dshComingSoon"),
			desc: t("hostDshDesc"),
		},
	];
	// ③ 签发面备注命名建议随已选宿主（host==="dsh" 时签发面不渲染，hostName 不会被消费）
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
				{t("wizardWhy")}
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
					{host === "dsh" && (
						<p className="connect-step-card__desc" style={{ marginTop: 12 }}>
							{t("dshComingSoonDesc")}
						</p>
					)}
				</li>

				{host !== "dsh" && (
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
								{host === "opencode" && (
									<>
										<WriteConfigStepCard variant="opencode" />
										<ConfigureTokenStepCard variant="opencode" />
										<ConfigNotesStepCard />
									</>
								)}
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
								) : (
									<McpTokenIssuePanel
										onSaved={() => setCompleted(true)}
										hostName={hostName}
									/>
								)}
							</div>
						</li>
					</>
				)}
			</ol>

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
