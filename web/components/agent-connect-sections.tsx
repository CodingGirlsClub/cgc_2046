"use client";

/**
 * 集成 - Agents 区接入引导内容段（单一内容源，plan 2026-08-22 first-mile-onboarding U4 / R4）。
 *
 * 原子页（openclacky / omp / opencode 三步引导页）与首公里向导
 * （onboarding-wizard.tsx）共用同一批内容卡；改文案/配置只改这里，
 * 原子页与向导不得各自复制出第二处内容源。
 *
 * 每个导出 = 一张 connect-step-card：
 * - OpenClacky：安装（iframe）/ 装扩展 / 生成 token 跳转卡（仅原子页用）
 * - OMP / opencode 手动配置：获取 token 跳转卡（仅原子页用）/ 写配置 / 配 token / 注意事项
 *
 * 步骤编号不在文案里：卡标题均为裸文案，编号由容器经 stepNo 供给——
 * 原子页传各自的「① / 2.」前缀（保持原有序列外观），首公里向导不传
 * （wizard 自己的 ol 已提供 ①②③ 步骤号，避免「② 内嵌 ①②」双重编号）。
 */
import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { Icon } from "@/components/icons";

/* ---------------- OpenClacky（官方下载 + 扩展市场） ---------------- */

/** 安装 OpenClacky（官方下载页 iframe embed） */
export function OpenclackyInstallCard({ stepNo }: { stepNo?: string }) {
	const t = useTranslations("agentConnect");
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("step1Openclacky")}</h2>
			<iframe
				src="https://www.openclacky.com/claw/cgc?embed=1"
				width="100%"
				height={300}
				style={{ border: "none", borderRadius: 12 }}
				allow="clipboard-write"
				loading="lazy"
				title={t("downloadTitle")}
			/>
		</div>
	);
}

/** 安装 CGC-2046 连接器扩展（OpenClacky 扩展市场） */
export function OpenclackyExtensionCard({ stepNo }: { stepNo?: string }) {
	const t = useTranslations("agentConnect");
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("step2Openclacky")}</h2>
			<p className="connect-step-card__desc">
				{t("extensionSearchHint")}
			</p>
			<ol
				style={{
					margin: "0 0 0 18px",
					padding: 0,
					display: "grid",
					gap: 6,
					color: "var(--ink-3)",
					fontSize: 13,
					lineHeight: "20px",
					listStyle: "decimal",
				}}
			>
				<li style={{ lineHeight: "20px" }}>
					{t("openMarket")}
				</li>
				<li style={{ lineHeight: "20px" }}>
					{t.rich("searchExtension", {
						code: (chunks) => <code>{chunks}</code>,
					})}
				</li>
				<li style={{ lineHeight: "20px" }}>
					{t("installExtension")}
				</li>
			</ol>
			<p className="connect-step-card__desc">
				{t("installedPanel")}
			</p>
		</div>
	);
}

/** 生成连接 token（跳转 MCP 页签发；仅原子页用，向导内嵌签发面板替代） */
export function OpenclackyTokenLinkCard({
	slug,
	stepNo,
}: {
	slug: string;
	stepNo?: string;
}) {
	const t = useTranslations("agentConnect");
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("step3Openclacky")}</h2>
			<p className="connect-step-card__desc">
				{t("generateTokenDesc")}
			</p>
			<div className="connect-step-card__actions">
				<Link
					href={`/w/${slug}/settings/integrations/agents/mcp`}
					className="join-button join-button--primary"
				>
					<Icon name="plus" />
					{t("generateToken")}
				</Link>
			</div>
		</div>
	);
}

/* ---------------- OMP / opencode（手动配置） ---------------- */

const OMP_CONFIG = `{
  "mcpServers": {
    "cgc-2046": {
      "type": "http",
      "url": "<MCP_URL>",
      "headers": { "Authorization": "Bearer \${CGC_TOKEN}" }
    }
  }
}`;

const OPCODE_CONFIG = `{
  "mcp": {
    "cgc-2046": {
      "type": "remote",
      "url": "<MCP_URL>",
      "oauth": false,
      "headers": { "Authorization": "Bearer {env:CGC_TOKEN}" }
    }
  }
}`;

/** 手动配置宿主（OMP / opencode）变体标识 */
export type ManualConfigVariant = "omp" | "opencode";

/** 获取 token（跳转 MCP 页签发；仅原子页用，向导内嵌签发面板替代） */
export function TokenLinkStepCard({
	slug,
	stepNo,
}: {
	slug: string;
	stepNo?: string;
}) {
	const t = useTranslations("agentConnect");
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("step1Title")}</h2>
			<p className="connect-step-card__desc">
				{t.rich("step1Desc", {
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
	);
}

/** 写入配置文件（omp → .mcp.json，opencode → opencode.json） */
export function WriteConfigStepCard({
	variant,
	stepNo,
}: {
	variant: ManualConfigVariant;
	stepNo?: string;
}) {
	const t = useTranslations("agentConnect");
	const isOmp = variant === "omp";
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("step2Title", { file: isOmp ? ".mcp.json" : "opencode.json" })}</h2>
			<p className="connect-step-card__desc">
				{isOmp
					? t.rich("step2DescRoot", {
							code: (chunks) => <code>{chunks}</code>,
							code2: (chunks) => <code>{chunks}</code>,
						})
					: t.rich("step2DescPlain", {
							code: (chunks) => <code>{chunks}</code>,
						})}
			</p>
			<pre
				style={{
					overflowX: "auto",
					padding: "12px 14px",
					borderRadius: "var(--radius-small)",
					background: "var(--soft)",
					margin: 0,
					fontSize: 12.5,
					lineHeight: "18px",
				}}
			>
				<code>{isOmp ? OMP_CONFIG : OPCODE_CONFIG}</code>
			</pre>
			<p className="connect-step-card__desc">
				{t.rich("urlNote", {
					code: (chunks) => <code>{chunks}</code>,
					code3: (chunks) => <code>{chunks}</code>,
					code4: (chunks) => <code>{chunks}</code>,
				})}
			</p>
		</div>
	);
}

/** 配置 token（环境变量插值说明，两宿主占位符不同） */
export function ConfigureTokenStepCard({
	variant,
	stepNo,
}: {
	variant: ManualConfigVariant;
	stepNo?: string;
}) {
	const t = useTranslations("agentConnect");
	const isOmp = variant === "omp";
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("step3Title")}</h2>
			<p className="connect-step-card__desc">
				{isOmp ? "omp " : "opencode "}
				{t.rich("step3DescEnv", {
					code: (chunks) => <code>{chunks}</code>,
					placeholder: isOmp ? "${CGC_TOKEN}" : "{env:CGC_TOKEN}",
				})}
			</p>
		</div>
	);
}

/** 注意事项（合并条目、token 绑用户不绑工作区） */
export function ConfigNotesStepCard() {
	const t = useTranslations("agentConnect");
	return (
		<div className="connect-step-card">
			<h2>{t("notesTitle")}</h2>
			<p className="connect-step-card__desc">
				{t.rich("notesDesc", {
					code: (chunks) => <code>{chunks}</code>,
				})}
			</p>
		</div>
	);
}
