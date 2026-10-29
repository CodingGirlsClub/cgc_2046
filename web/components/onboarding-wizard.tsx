"use client";

/**
 * 首公里接入向导（plan 2026-08-22 first-mile-onboarding U4，R4–R7）。
 *
 * 结构：开场（欢迎 + 为什么接入）+ 纵向 stepper 三步，无硬门、进度不落库：
 * ① 安装 OpenClacky / ② 安装 CGC-2046 连接器扩展 / ③ 连接 CGC-2046
 *    （一键连接为主，手动 token 备用；卡片与原子页同一内容源，
 *    见 @/components/agent-connect-sections）。
 *
 * 三步对所有状态始终渲染且可见（不卸载、不 hidden）。
 *
 * readOnly（管理态「重新查看引导」回看）：stepper 内容在，但无签发面——
 * ③ 只给 MCP 页链接（签发归 mcp tab）。
 *
 * 有任何 token 记录（含全撤销/过期）的用户在向导态保留管理态入口（链 mcp tab）；
 * hasTokenHistory 由调用方从 useOnboardingState().tokens 派生传入（同一数据源，
 * 本组件不再二次 fetch）。
 *
 * stepper 当前步（aria-current + 左侧品牌色条）：①② 为自助阅读，唯一可判定
 * 「待办」的动作步是 ③ 连接。
 */

import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import {
	OpenclackyInstallCard,
	OpenclackyExtensionCard,
	OpenclackyConnectCard,
	OpenclackyAssistantHint,
} from "@/components/agent-connect-sections";

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

	// ③ 是唯一带动作信号的步骤（连接 / 签发），①② 为自助阅读。
	// 高亮 = 左侧品牌色条；三步都是卡片，不再补 padding
	const currentStep: number = 3;
	const stepStyle = (n: number) =>
		currentStep === n ? { borderLeft: "3px solid var(--brand)" } : {};

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
					data-testid="onboarding-step-1"
					aria-current={currentStep === 1 ? "step" : undefined}
					style={stepStyle(1)}
				>
					<OpenclackyInstallCard />
				</li>

				<li
					data-testid="onboarding-step-2"
					aria-current={currentStep === 2 ? "step" : undefined}
					style={stepStyle(2)}
				>
					<OpenclackyExtensionCard />
				</li>

				<li
					data-testid="onboarding-step-3"
					aria-current={currentStep === 3 ? "step" : undefined}
					style={stepStyle(3)}
				>
					{readOnly ? (
						<div className="connect-step-card">
							<h2>{tConnect("step3Openclacky")}</h2>
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
						<>
							<OpenclackyConnectCard slug={slug} />
							{/* 签发只到剪贴板，须回 CGC 助手会话触发扩展 /connect
							    才真正写入 mcp.json（P1 补回） */}
							<OpenclackyAssistantHint />
						</>
					)}
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
