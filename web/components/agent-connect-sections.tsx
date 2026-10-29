"use client";

/**
 * 集成 - Agents 区接入引导内容段（单一内容源，plan 2026-08-22 first-mile-onboarding U4 / R4）。
 *
 * 原子页（openclacky 三步引导页）与首公里向导
 * （onboarding-wizard.tsx）共用同一批内容卡；改文案/配置只改这里，
 * 原子页与向导不得各自复制出第二处内容源。
 *
 * 每个导出 = 一张 connect-step-card：
 * - OpenClacky：安装（iframe）/ 装扩展（一条命令）/ 连接卡（一键连接为主，
 *   手动 token 备用）/ 助手接入指引段（仅向导用）
 *
 * 步骤编号不在文案里：卡标题均为裸文案，编号由容器经 stepNo 供给——
 * 原子页传各自的「① / 2.」前缀（保持原有序列外观），首公里向导不传
 * （wizard 自己的 ol 已提供 ①②③ 步骤号，避免「② 内嵌 ①②」双重编号）。
 */
import { useEffect, useRef, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { Icon } from "@/components/icons";
import { copyText } from "@/lib/clipboard";

/* ---------------- OpenClacky（CGC OpenClacky 一键安装，扩展已内置） ---------------- */

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

/** 自托管分发安装命令（分发渠道从公共市场转自托管，plan cgc-2046 扩展分发迁移） */
const EXT_INSTALL_CMD =
	"openclacky ext install https://api.codingirlsclub.com/ext/cgc-2046.zip";

/** 定时器句柄（「已复制」2s 复位用；DOM/Node 两端 setTimeout 返回型不同） */
type TimerHandle = ReturnType<typeof setTimeout>;

/** CGC-2046 连接器扩展安装卡：终端一条命令安装（zip 由 CGC 后端自托管分发） */
export function OpenclackyExtensionCard({ stepNo }: { stepNo?: string }) {
	const t = useTranslations("agentConnect");
	const [copied, setCopied] = useState(false);
	const [copyFailed, setCopyFailed] = useState(false);
	// 卸载时清理复位定时器（向导完成换树卸载本组件，旧定时器会对已卸载组件 setState）
	const copiedTimerRef = useRef<TimerHandle | undefined>(undefined);
	useEffect(() => () => clearTimeout(copiedTimerRef.current), []);
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("step2Openclacky")}</h2>
			<p className="connect-step-card__desc">{t("extensionInstallDesc")}</p>
			<div style={{ display: "flex", gap: 8, alignItems: "flex-start" }}>
				<pre
					style={{
						overflowX: "auto",
						padding: "12px 14px",
						borderRadius: "var(--radius-small)",
						background: "var(--soft)",
						margin: 0,
						fontSize: 12.5,
						lineHeight: "18px",
						flex: 1,
					}}
				>
					<code>{EXT_INSTALL_CMD}</code>
				</pre>
				<button
					type="button"
					className="join-button join-button--outline"
					onClick={() => {
						void copyText(EXT_INSTALL_CMD).then((ok) => {
							if (ok) {
								setCopied(true);
								setCopyFailed(false);
								clearTimeout(copiedTimerRef.current);
								copiedTimerRef.current = setTimeout(() => setCopied(false), 2000);
							} else {
								setCopyFailed(true);
							}
						});
					}}
				>
					{copied ? t("copied") : t("copyCommand")}
				</button>
			</div>
			{copyFailed && (
				<p className="connect-step-card__desc" role="alert">
					{t("copyFailed")}
				</p>
			)}
			<p className="connect-step-card__desc">
				{t("installedPanel")}
			</p>
		</div>
	);
}

/** 连接 CGC-2046（仅原子页用）：主路径 = 面板「连接网站」一键连接（token
    不经用户手）；手动 token 为备用（自动连接不可用时，跳 MCP 页签发）。
    向导 ③ 为内嵌签发面板 + oneClickConnect 卡，不复用本卡 */
export function OpenclackyConnectCard({
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
				{t("oneClickConnectDesc")}
			</p>
			<div className="connect-step-card__actions">
				<a
					href="http://127.0.0.1:7070"
					target="_blank"
					rel="noopener noreferrer"
					className="join-button join-button--primary"
				>
					{t("openCgcOpenclacky")}
				</a>
			</div>
			<p className="connect-step-card__desc">
				{t("generateTokenDesc")}
			</p>
			<div className="connect-step-card__actions">
				<Link
					href={`/w/${slug}/settings/integrations/agents/mcp`}
					className="join-button join-button--outline"
				>
					<Icon name="plus" />
					{t("generateToken")}
				</Link>
			</div>
		</div>
	);
}

/** 回 CGC 助手完成接入指引（仅首公里向导用；原子页同段说明在 ③ 的
    generateTokenDesc 里）。缺这段：token 只躺在剪贴板，无人触发扩展 /connect
    写入 ~/.clacky/mcp.json，agent 首联必失败（review P1 补回） */
export function OpenclackyAssistantHint() {
	const t = useTranslations("agentConnect");
	return (
		<p className="connect-step-card__desc">
			{t("assistantConnectHint")}
		</p>
	);
}
