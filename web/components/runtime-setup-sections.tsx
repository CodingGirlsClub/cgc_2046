"use client";

/**
 * 环境准备 - 终端 + Herdr 安装内容段（单一内容源）。
 *
 * 首公里向导（omp / opencode / dsh 路径）、agents 原子页（omp / opencode）
 * 与 /setup 独立落地页共用本卡；改文案/命令只改这里（i18n：agentConnect
 * 的 runtime* / setup* keys），消费方不得各自复制第二处内容源。
 *
 * 平台分支（macOS = Ghostty；Windows = Windows Terminal 主线 + WezTerm
 * 附注）：平台态由 RuntimeSetupCards 持有并共享给三张卡（任一处切换，
 * 三段同步）。SSR 首帧固定 Windows，装载后按 UA 修正（useSyncExternalStore
 * 快照，不经 effect setState）——检测只做预选不做死，用户随时手动切换。
 *
 * 宿主映射：OpenClacky 不渲染本组卡（桌面应用自带环境，唯一终端触点是
 * 一条 ext install 命令，原配终端可跑）；映射表在 onboarding-wizard.tsx
 * 的 PREP_HOSTS。
 *
 * 命令与平台事实来源：herdr.dev/docs/install 与 herdr.dev/docs/windows-beta
 * （Windows 原生验证过的宿主终端是 Windows Terminal / Alacritty，WezTerm
 * 仅 WSL 托管路径被验证；Herdr 二进制未做代码签名，Windows SmartScreen
 * 会拦截首启）。
 */
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useTranslations } from "next-intl";
import { copyText } from "@/lib/clipboard";

/** 环境准备覆盖的桌面平台（tab 粒度；Linux 用户直接看 herdr.dev 官网） */
type DesktopOS = "mac" | "windows";

function detectOS(): DesktopOS {
	return /Mac|iPhone|iPad/i.test(navigator.userAgent) ? "mac" : "windows";
}

/** 空订阅：UA 只在装载后读一次快照，无外部源可订阅 */
const noopSubscribe = () => () => {};

/** SSR 首帧快照：受众以 Windows 小白为主，首帧按 Windows 渲染避免布局跳动 */
const SSR_OS: DesktopOS = "windows";

/** macOS 安装命令（herdr.dev/docs/install） */
const HERDR_INSTALL_MAC = "curl -fsSL https://herdr.dev/install.sh | sh";

/** Windows 安装命令（PowerShell；被端点安全拦截时走下方 cmd 回退） */
const HERDR_INSTALL_WIN_PS =
	'powershell -ExecutionPolicy Bypass -c "irm https://herdr.dev/install.ps1 | iex"';

/** Windows cmd 回退（杀软拦截 fileless PowerShell 时） */
const HERDR_INSTALL_WIN_CMD =
	"curl.exe -fsSLo install.cmd https://herdr.dev/install.cmd && install.cmd && del install.cmd";

/** 安装验证命令 */
const HERDR_VERIFY_CMD = "herdr";

/** 「已复制」提示 2s 复位定时器（DOM setTimeout，client 组件恒 number） */
type CopiedTimer = number;

/** 一条可复制命令块（样式与复制交互同 agent-connect-sections 的命令卡） */
function CommandBlock({ command }: { command: string }) {
	const t = useTranslations("agentConnect");
	const [copied, setCopied] = useState(false);
	const [copyFailed, setCopyFailed] = useState(false);
	const copiedTimerRef = useRef<CopiedTimer | undefined>(undefined);
	useEffect(() => () => clearTimeout(copiedTimerRef.current), []);
	return (
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
				<code>{command}</code>
			</pre>
			<button
				type="button"
				className="join-button join-button--outline"
				onClick={() => {
					void copyText(command).then((ok) => {
						if (ok) {
							setCopied(true);
							setCopyFailed(false);
							clearTimeout(copiedTimerRef.current);
							copiedTimerRef.current = window.setTimeout(
								() => setCopied(false),
								2000,
							);
						} else {
							setCopyFailed(true);
						}
					});
				}}
			>
				{copied ? t("copied") : t("copyCommand")}
			</button>
			{copyFailed && (
				<p className="connect-step-card__desc" role="alert">
					{t("copyFailed")}
				</p>
			)}
		</div>
	);
}

/** macOS / Windows 切换（tab 语义，选中态品牌色描边） */
function PlatformTabs({
	os,
	onChange,
}: {
	os: DesktopOS;
	onChange: (os: DesktopOS) => void;
}) {
	const t = useTranslations("agentConnect");
	return (
		<div
			role="tablist"
			aria-label={t("runtimePlatformAria")}
			style={{ display: "flex", gap: 8 }}
		>
			{(["mac", "windows"] as const).map((p) => (
				<button
					key={p}
					type="button"
					role="tab"
					aria-selected={os === p}
					className="join-button join-button--outline"
					onClick={() => onChange(p)}
					style={
						os === p
							? { borderColor: "var(--brand)", color: "var(--brand)" }
							: undefined
					}
				>
					{p === "mac" ? t("runtimePlatformMac") : t("runtimePlatformWindows")}
				</button>
			))}
		</div>
	);
}

/** Windows 新手告警盒（SmartScreen / 粘贴键 / 中文输入法候选框） */
function WindowsWarnBox() {
	const t = useTranslations("agentConnect");
	return (
		<div
			role="note"
			style={{
				padding: "10px 12px",
				borderRadius: "var(--radius-small)",
				background: "var(--soft)",
				display: "grid",
				gap: 6,
			}}
		>
			<strong className="connect-step-card__desc" style={{ margin: 0 }}>
				{t("runtimeWinWarnTitle")}
			</strong>
			<ul
				className="connect-step-card__desc"
				style={{ margin: 0, paddingLeft: 20, display: "grid", gap: 6 }}
			>
				<li>{t("runtimeWinWarnSmartScreen")}</li>
				<li>{t("runtimeWinWarnPaste")}</li>
				<li>{t("runtimeWinWarnIme")}</li>
			</ul>
		</div>
	);
}

/**
 * 环境准备三卡：① 终端 ② 安装 Herdr ③ 验证（含平台共享态）。
 * stepNos 依次为三张卡的编号前缀（原子页传「1./2./3.」，向导不传——
 * wizard 自己的 ol 已提供步骤号，避免「② 内嵌 ①②③」双重编号）。
 */
export function RuntimeSetupCards({
	stepNos = [],
}: {
	stepNos?: string[];
}) {
	const t = useTranslations("agentConnect");
	// UA 检测只做预选；用户手动切换后以手动选择为准（override 非空）
	const detected = useSyncExternalStore(noopSubscribe, detectOS, () => SSR_OS);
	const [override, setOverride] = useState<DesktopOS | null>(null);
	const os = override ?? detected;
	const [n1, n2, n3] = stepNos;
	const isMac = os === "mac";

	return (
		<>
			<div className="connect-step-card">
				<h2>
					{n1 ? `${n1} ` : ""}
					{t("runtimeTerminalTitle")}
				</h2>
				<PlatformTabs os={os} onChange={setOverride} />
				{isMac ? (
					<>
						<p className="connect-step-card__desc">
							{t("runtimeTerminalMacIntro")}
						</p>
						<ol
							className="connect-step-card__desc"
							style={{ margin: 0, paddingLeft: 20, display: "grid", gap: 6 }}
						>
							<li>{t("runtimeTerminalMacStep1")}</li>
							<li>{t("runtimeTerminalMacStep2")}</li>
							<li>{t("runtimeTerminalMacStep3")}</li>
						</ol>
					</>
				) : (
					<>
						<p className="connect-step-card__desc">
							{t("runtimeTerminalWin11")}
						</p>
						<p className="connect-step-card__desc">
							{t("runtimeTerminalWin10")}
						</p>
						<p className="connect-step-card__desc">
							{t("runtimeWeztermNote")}
						</p>
					</>
				)}
			</div>

			<div className="connect-step-card">
				<h2>
					{n2 ? `${n2} ` : ""}
					{t("runtimeHerdrTitle")}
				</h2>
				<p className="connect-step-card__desc">
					{isMac ? t("runtimeHerdrMacDesc") : t("runtimeHerdrWinDesc")}
				</p>
				<CommandBlock command={isMac ? HERDR_INSTALL_MAC : HERDR_INSTALL_WIN_PS} />
				{!isMac && (
					<>
						<p className="connect-step-card__desc">
							{t("runtimeHerdrWinFallback")}
						</p>
						<CommandBlock command={HERDR_INSTALL_WIN_CMD} />
					</>
				)}
			</div>

			<div className="connect-step-card">
				<h2>
					{n3 ? `${n3} ` : ""}
					{t("runtimeVerifyTitle")}
				</h2>
				<p className="connect-step-card__desc">{t("runtimeVerifyDesc")}</p>
				<CommandBlock command={HERDR_VERIFY_CMD} />
				<p className="connect-step-card__desc">{t("runtimeVerifyOk")}</p>
				{!isMac && <WindowsWarnBox />}
			</div>
		</>
	);
}
