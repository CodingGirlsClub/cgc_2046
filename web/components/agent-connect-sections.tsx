"use client";

/**
 * 集成 - Agents 区接入引导内容段（单一内容源，plan 2026-08-22 first-mile-onboarding U4 / R4）。
 *
 * 原子页（openclacky / omp / opencode 三步引导页）与首公里向导
 * （onboarding-wizard.tsx）共用同一批内容卡；改文案/配置只改这里，
 * 原子页与向导不得各自复制出第二处内容源。
 *
 * 每个导出 = 一张 connect-step-card：
 * - OpenClacky：安装（iframe）/ 装扩展（一条命令）/ 连接卡（一键连接为主，
 *   手动 token 备用；仅原子页用）/ 助手接入指引段（仅向导用，手动 token 备用）
 * - OMP / opencode 手动配置：获取 token 跳转卡（仅原子页用）/ 写配置 / 配 token / 注意事项
 * - opencode OAuth 五步链（U8，plan 2026-09-15 opencode-desktop-host）：安装 →
 *   模型获取 → 打开学习空间（下载 + 深链）→ 授权连接（等待态）→ 验证；
 *   手动配置降为「开发者选项」折叠内（WriteConfigStepCard 等原卡复用）
 * - DSH：插件家族安装指引卡（仅向导用；手动流，无自动连接等价物，
 *   plan 2026-09-08 DSH parity U10 / R17）
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
import type { OpencodeAuthPhase } from "@/lib/use-opencode-auth-phase";

/** 平台分发面（扩展 zip / 学习空间包同一 api 域） */
const API_ORIGIN = "https://api.codingirlsclub.com";

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
const EXT_INSTALL_CMD = `openclacky ext install ${API_ORIGIN}/ext/cgc-2046.zip`;

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

/* ---------------- OMP / opencode（手动配置） ---------------- */

const OMP_CONFIG = `{
  "mcpServers": {
    "cgc-2046": {
      "type": "http",
      "url": "https://api.codingirlsclub.com/mcp",
      "headers": { "Authorization": "Bearer \${CGC_TOKEN}" }
    }
  }
}`;

const OPCODE_CONFIG = `{
  "mcp": {
    "cgc-2046": {
      "type": "remote",
      "url": "https://api.codingirlsclub.com/mcp",
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

/* ---------------- DSH（插件家族手动接入：装插件 → 面板粘贴 token） ---------------- */

/** 安装 DSH 插件家族指引（plan 2026-09-08 DSH parity U10 / R17）。
    DSH 无自动连接等价物（无 connector 扩展可配 MCP），唯一流程 =
    `dsh plugin --profile web add dsh-cgc-all` 装插件 → 向导 ③ 签发 token →
    在 DSH 面板表单粘贴。文案含包名完整性提示（RSK1：防 npm 抢注仿冒）与
    粘贴后清空剪贴板建议（RSK7：token 生命周期暴露面低成本加固） */
export function DshInstallCard({ stepNo }: { stepNo?: string }) {
	const t = useTranslations("agentConnect");
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("step1Dsh")}</h2>
			<p className="connect-step-card__desc">
				{t.rich("dshInstallDesc", {
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
				<code>dsh plugin --profile web add dsh-cgc-all</code>
			</pre>
			<p className="connect-step-card__desc">{t("dshManualFlowDesc")}</p>
			<p className="connect-step-card__desc">{t("dshIntegrityHint")}</p>
			<p className="connect-step-card__desc">{t("dshClipboardHint")}</p>
		</div>
	);
}

/* ---------------- opencode（官方 Desktop + 学习空间包 + OAuth 五步接入，U8） ---------------- */

/** 学习空间包 zip 直链（U7 产物；与扩展安装命令同源 api 域） */
const LEARN_SPACE_ZIP_URL = `${API_ORIGIN}/ext/learn-space.zip`;
/** 三键版本 JSON 走 Next 同源代理（/ext 由 Plug.Static 先于 CORSPlug 服务，跨域 fetch 无 CORS 头） */
const LEARN_SPACE_META_URL = "/ext/learn-space.json";
/** opencode 官方下载页（R1：只走官方渠道） */
const OPENCODE_DOWNLOAD_URL = "https://opencode.ai/download";

/** 宿主平台（U8 平台差异文案） */
type HostPlatform = "mac" | "win";

/** 学习空间固定目录（KTD7：名称固定、跨平台同构；Windows 的实际路径以资源管理器为准） */
const LEARN_SPACE_PATH: Record<HostPlatform, string> = {
	mac: "~/Documents/CGC-2046",
	win: "%USERPROFILE%\\Documents\\CGC-2046",
};

/** UA 只在客户端可得：挂载后经 queueMicrotask 应用（SSR 首帧按 macOS 渲染，
    与 theme-provider 同款，杜绝 hydration mismatch） */
function useHostPlatform(): HostPlatform {
	const [platform, setPlatform] = useState<HostPlatform>("mac");
	useEffect(() => {
		queueMicrotask(() => {
			setPlatform(/Windows/i.test(navigator.userAgent) ? "win" : "mac");
		});
	}, []);
	return platform;
}

/** 宿主深链（R4）：open-project + directory（路径 URL 编码）。
    U2 ① 的深链行为待真机复核 → 卡内必须并列手动回退（按钮没反应就手动打开文件夹） */
function learnSpaceDeepLink(platform: HostPlatform): string {
	return `opencode://open-project?directory=${encodeURIComponent(LEARN_SPACE_PATH[platform])}`;
}

/** 三键版本 JSON（U7 契约：version / download_path / sha256） */
interface LearnSpaceRelease {
	version: string;
	download_path: string;
	sha256: string;
}

/** 读发布版本与指纹；取不到返回 null（引导降级为「直接下载最新包」，不阻断下载） */
function useLearnSpaceRelease(): LearnSpaceRelease | null {
	const [release, setRelease] = useState<LearnSpaceRelease | null>(null);
	useEffect(() => {
		let cancelled = false;
		fetch(LEARN_SPACE_META_URL)
			.then((res) => (res.ok ? (res.json() as Promise<LearnSpaceRelease>) : null))
			.then((data) => {
				if (cancelled || !data?.version || !data.sha256) return;
				setRelease(data);
			})
			.catch(() => {
				// 版本信息非关键路径：失败保留「直接下载最新包」的降级文案
			});
		return () => {
			cancelled = true;
		};
	}, []);
	return release;
}

/** ① 安装 opencode Desktop（官方渠道；macOS / Windows 分平台说明） */
export function OpencodeInstallCard({ stepNo }: { stepNo?: string }) {
	const t = useTranslations("agentConnect");
	const platform = useHostPlatform();
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("opencodeStepInstall")}</h2>
			<p className="connect-step-card__desc">{t("opencodeInstallDesc")}</p>
			<p className="connect-step-card__desc">
				{platform === "win"
					? t("opencodeInstallWin")
					: t("opencodeInstallMac")}
			</p>
			<div className="connect-step-card__actions">
				<a
					href={OPENCODE_DOWNLOAD_URL}
					target="_blank"
					rel="noreferrer"
					className="join-button join-button--primary"
				>
					{t("opencodeDownloadOfficial")}
				</a>
			</div>
		</div>
	);
}

/** ② 模型获取：推荐通道（DeepSeek 官方 API）+ 费用说明 + 一条可自查的可用性检查 */
export function OpencodeModelCard({ stepNo }: { stepNo?: string }) {
	const t = useTranslations("agentConnect");
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("opencodeStepModel")}</h2>
			<p className="connect-step-card__desc">
				{t.rich("opencodeModelDesc", {
					code: (chunks) => <code>{chunks}</code>,
					code2: (chunks) => <code>{chunks}</code>,
				})}
			</p>
			<p className="connect-step-card__desc">{t("opencodeModelCost")}</p>
			<p className="connect-step-card__desc">{t("opencodeModelAlt")}</p>
			<p className="connect-step-card__desc">{t("opencodeModelCheck")}</p>
		</div>
	);
}

/** ③ 打开学习空间：zip 直链 + 发布版本/指纹 + 深链（含手动回退）+ 重启提示（U2 ① 结论） */
export function OpencodeLearnSpaceCard({ stepNo }: { stepNo?: string }) {
	const t = useTranslations("agentConnect");
	const platform = useHostPlatform();
	const release = useLearnSpaceRelease();
	// 下载地址优先用三键 JSON 的 download_path（产物契约），取不到回退固定直链
	const zipUrl = release?.download_path
		? `${API_ORIGIN}${release.download_path}`
		: LEARN_SPACE_ZIP_URL;
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("opencodeStepLearnSpace")}</h2>
			<p className="connect-step-card__desc">
				{t.rich("opencodeLearnSpaceDesc", {
					dir:
						platform === "win"
							? t("opencodeLearnSpaceDirWin")
							: t("opencodeLearnSpaceDirMac"),
					path: LEARN_SPACE_PATH[platform],
					code: (chunks) => <code>{chunks}</code>,
					code2: (chunks) => <code>{chunks}</code>,
				})}
			</p>
			{platform === "win" && (
				<p className="connect-step-card__desc">
					{t("opencodeLearnSpaceWinNote")}
				</p>
			)}
			<div className="connect-step-card__actions">
				<a
					href={zipUrl}
					className="join-button join-button--primary"
					download
				>
					{t("opencodeDownloadZip")}
				</a>
				<a
					href={learnSpaceDeepLink(platform)}
					className="join-button join-button--outline"
				>
					{t("opencodeDeepLink")}
				</a>
			</div>
			<p
				className="connect-step-card__desc"
				data-testid="learn-space-release"
			>
				{release ? (
					<>
						{t("opencodeReleaseVersion", { version: release.version })}
						{" · "}
						{t("opencodeReleaseShaLabel")}{" "}
						<code style={{ wordBreak: "break-all" }}>{release.sha256}</code>
					</>
				) : (
					t("opencodeReleaseUnavailable")
				)}
			</p>
			<p className="connect-step-card__desc">
				{t.rich("opencodeLearnSpaceZipHint", {
					code: (chunks) => <code>{chunks}</code>,
				})}
			</p>
			<p className="connect-step-card__desc">{t("opencodeDeepLinkFallback")}</p>
			<p className="connect-step-card__desc">{t("opencodeRestartHint")}</p>
		</div>
	);
}

/**
 * ④ 授权连接：等待态按平台侧授权阶段区分（idle = 尚未触发 / pending = 授权进行中 /
 * active = 已完成）；回调超时与端口占用的恢复入口也在此卡（同意页不承载）。
 * onRecheck 缺省（如只读回看）时不渲染「检查状态」按钮。
 */
export function OpencodeAuthorizeCard({
	stepNo,
	phase = "idle",
	onRecheck,
}: {
	stepNo?: string;
	phase?: OpencodeAuthPhase;
	onRecheck?: () => void;
}) {
	const t = useTranslations("agentConnect");
	if (phase === "active") {
		return (
			<div className="connect-step-card">
				<h2>{stepNo ? `${stepNo} ` : ""}{t("opencodeStepAuthorize")}</h2>
				<p className="connect-step-card__desc">
					{t("opencodeAuthorizeActive")}
				</p>
			</div>
		);
	}
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("opencodeStepAuthorize")}</h2>
			<p className="connect-step-card__desc">{t("opencodeAuthorizeDesc")}</p>
			{phase === "pending" ? (
				<>
					<p className="connect-step-card__desc">
						<strong>{t("opencodeAuthorizePendingTitle")}</strong>
					</p>
					<p className="connect-step-card__desc">
						{t("opencodeAuthorizePending")}
					</p>
					<p className="connect-step-card__desc">
						{t("opencodeAuthorizePendingBrowserFail")}
					</p>
				</>
			) : (
				<>
					<p className="connect-step-card__desc">
						<strong>{t("opencodeAuthorizeIdleTitle")}</strong>
					</p>
					<p className="connect-step-card__desc">{t("opencodeAuthorizeIdle")}</p>
				</>
			)}
			<p className="connect-step-card__desc">
				<strong>{t("opencodeAuthorizeRecoverTitle")}</strong>
			</p>
			<p className="connect-step-card__desc">
				{t("opencodeAuthorizeRecover")}
			</p>
			{onRecheck && (
				<div className="connect-step-card__actions">
					<button
						type="button"
						className="join-button join-button--outline"
						onClick={onRecheck}
					>
						{t("opencodeAuthorizeCheck")}
					</button>
				</div>
			)}
			<p className="connect-step-card__desc">
				{t("opencodeAuthorizeAutoHint")}
			</p>
			<p className="connect-step-card__desc">
				{t("opencodeAuthorizeSharedDevice")}
			</p>
		</div>
	);
}

/** ⑤ 验证连接：一句话自查 + 判定来源（平台侧「最近使用」）+ 重启提示 */
export function OpencodeVerifyCard({ stepNo }: { stepNo?: string }) {
	const t = useTranslations("agentConnect");
	return (
		<div className="connect-step-card">
			<h2>{stepNo ? `${stepNo} ` : ""}{t("opencodeStepVerify")}</h2>
			<p className="connect-step-card__desc">{t("opencodeVerifyDesc")}</p>
			<p className="connect-step-card__desc">
				<code>{t("opencodeVerifySeed")}</code>
			</p>
			<p className="connect-step-card__desc">{t("opencodeVerifySource")}</p>
			<p className="connect-step-card__desc">
				{t.rich("opencodeVerifyStatus", {
					code: (chunks) => <code>{chunks}</code>,
				})}
			</p>
			<p className="connect-step-card__desc">
				{t("opencodeVerifyRestartHint")}
			</p>
		</div>
	);
}

/** 开发者选项（默认收起）：手动配置路径（token 签发 → 写 opencode.json → 配置插值 → 注意事项） */
export function OpencodeDeveloperOptions({ slug }: { slug: string }) {
	const t = useTranslations("agentConnect");
	return (
		<details
			className="connect-step-card"
			data-testid="opencode-developer-options"
		>
			<summary style={{ cursor: "pointer" }}>{t("opencodeDevSummary")}</summary>
			<p className="connect-step-card__desc" style={{ marginTop: 12 }}>
				{t("opencodeDevDesc")}
			</p>
			<div style={{ display: "grid", gap: 16, marginTop: 12 }}>
				<TokenLinkStepCard slug={slug} />
				<WriteConfigStepCard variant="opencode" />
				<ConfigureTokenStepCard variant="opencode" />
				<ConfigNotesStepCard />
			</div>
		</details>
	);
}
