"use client";

/**
 * 集成 - opencode（U8，plan 2026-09-15 opencode-desktop-host）。
 *
 * 五步接入引导（OAuth 主路径，R1–R4 / R19）：
 * ① 安装官方 opencode Desktop → ② 获取一个可用模型 → ③ 打开学习空间
 * （下载 zip + 宿主深链）→ ④ 授权连接（浏览器 OAuth，等待态区分
 * 「尚未触发 / 授权进行中」）→ ⑤ 验证连接。全程不接触 token。
 * 手动配置（签发 token + 写 opencode.json）收进「开发者选项」折叠。
 *
 * 内容卡为共享组件（@/components/agent-connect-sections，
 * 首公里向导复用同一内容源，per plan first-mile-onboarding R4）。
 * 第④步等待态由 useOpencodeAuthPhase 驱动——与向导同一信号源（平台授权记录）。
 */

import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { useOpencodeAuthPhase } from "@/lib/use-opencode-auth-phase";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";
import {
	OpencodeInstallCard,
	OpencodeModelCard,
	OpencodeLearnSpaceCard,
	OpencodeAuthorizeCard,
	OpencodeVerifyCard,
	OpencodeDeveloperOptions,
} from "@/components/agent-connect-sections";

export default function AgentsOpencodePage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws } = useWorkspaceBySlug(slug);
	const t = useTranslations("agentConnect");
	const tCommon = useTranslations("common");
	// 第④步等待态：平台侧授权记录（idle / pending / active），focus + 30s 兜底重查
	const { phase, recheck } = useOpencodeAuthPhase(true);

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/settings/join-policy`}>
						{t("breadcrumbSettings")}
					</Link>
					<span>›</span>
					<strong>{t("titleOpencode")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("titleOpencode")}</h1>
						<p>{t("subtitleOpencode")}</p>
					</div>
				</header>

				<IntegrationsAgentsTabs slug={slug} current="agents-opencode" abilities={[]} />

				<div style={{ display: "grid", gap: 16, marginTop: 16 }}>
					<OpencodeInstallCard stepNo="①" />
					<OpencodeModelCard stepNo="②" />
					<OpencodeLearnSpaceCard stepNo="③" />
					<OpencodeAuthorizeCard stepNo="④" phase={phase} onRecheck={recheck} />
					<OpencodeVerifyCard stepNo="⑤" />
					<OpencodeDeveloperOptions slug={slug} />
				</div>
			</div>
		</WorkspaceShell>
	);
}
