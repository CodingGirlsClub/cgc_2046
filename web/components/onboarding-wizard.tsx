"use client";

/**
 * 首公里接入向导（plan 2026-08-22 first-mile-onboarding U4，R4–R7）。
 *
 * 结构：开场（欢迎 + 为什么接入）+ 纵向 stepper 三步，无硬门、进度不落库：
 * ① 选宿主：OpenClacky（默认推荐）/ OMP / opencode / DSH 单选
 *    （DSH 自 plan 2026-09-08 DSH parity U10 / R17 起正式开放，手动流：
 *    装插件家族 → ③ 签发 token → 面板粘贴，无自动连接等价物）；
 * ② 安装与配置：内容按宿主映射共享内容卡（@/components/agent-connect-sections，
 *    与原子页同一内容源，per R4）；
 * ③ 生成连接 token：内嵌 McpTokenIssuePanel（与 mcp 页同一签出面），
 *    「我已保存」确认即完成判定（两段式第一段，per Key Decision），进完成态
 *    （种子话术卡 + 出口：去概览 / 看活动）。完成态仅当次会话（组件 state）。
 *    OpenClacky 路径附「回 CGC 助手完成接入」指引段（OpenclackyAssistantHint）——
 *    缺它 token 只躺在剪贴板，无人触发扩展 /connect 写入 mcp.json，首联必失败。
 *
 * ②③ 对所有宿主始终渲染且可见（不卸载、不 hidden）：③ 签发面的一次性明文
 * 与在途签发请求是组件内 state，卸载/隐藏语义曾让服务端已签发 token 的明文
 * 面临丢失风险（P2）；DSH 启用后四宿主统一此行为。
 *
 * readOnly（管理态「重新查看引导」回看）：stepper 内容在，但无签发面——
 * ③ 只给 MCP 页链接（签发归 mcp tab）。
 *
 * 有任何 token 记录（含全撤销/过期）的用户在向导态保留管理态入口（链 mcp tab）；
 * hasTokenHistory 由调用方从 useOnboardingState().tokens 派生传入（同一数据源，
 * 本组件不再二次 fetch）。
 *
 * stepper 当前步（aria-current + 左侧品牌色条）：①②无完成信号可追踪
 * （宿主默认已选、安装为自助阅读），唯一可判定「待办」的动作步是 ③ 签发，
 * 四种宿主一致。
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

	// stepper 当前步：③ 是唯一带完成信号的动作步（签发 + 「我已保存」），
	// ①② 为自助阅读，四种宿主一致停在 ③。
	// 高亮 = 左侧品牌色条；card 步（①）自带内边距，只描边不补 padding
	const currentStep: number = 3;
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
				</li>

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
								onSaved={() => setCompleted(true)}
								hostName={hostName}
							/>
						)}
						{/* OpenClacky 路径：签发只到剪贴板，须回 CGC 助手会话
						    触发扩展 /connect 才真正写入 mcp.json（P1 补回） */}
						{host === "openclacky" && <OpenclackyAssistantHint />}
					</div>
				</li>
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
