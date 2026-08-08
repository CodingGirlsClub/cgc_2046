"use client";

/**
 * 切片 D（#44）连接引导页 /w/[slug]/connect —— 三步向导。
 *
 * 1 安装 MCP 客户端（OpenClacky / omp / opencode 安装指引 Tab）
 * 2 生成连接 token（内嵌签发；检测到已有有效 token 时提示可跳过）
 * 3 拷贝配置（三客户端配置片段 Tab，占位符版本，D-D10）
 *
 * token 管理（列表/撤销）在连接设置页 /w/[slug]/settings/connection。
 */

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	fetchMyMcpTokens,
	issueMcpToken,
	MCP_CLIENTS,
	type McpClientKey,
	type McpTokenItem,
} from "@/lib/mcp";
import WorkspaceShell from "@/components/workspace-shell";
import McpConfigSnippet from "@/components/mcp-config-snippet";
import { copyText } from "@/lib/clipboard";

const STEPS = ["安装客户端", "生成连接 token", "拷贝配置"] as const;

const INSTALL_HINTS: Record<
	McpClientKey,
	{ command: string; description: string }
> = {
	openclacky: {
		command: "gem install openclacky",
		description:
			"Ruby gem 形态的 agent CLI。安装完成后进入第 3 步，把 cgc 配置合并进 ~/.clacky/mcp.json。",
	},
	omp: {
		command: "# 安装见 github.com/can1357/oh-my-pi",
		description:
			"oh-my-pi agent CLI。配置写入项目根目录 .mcp.json（与 Claude 系配置格式兼容）。",
	},
	opencode: {
		command: "npm install -g opencode-ai",
		description:
			"SST 出品的终端 agent（详见 opencode.ai）。配置写入项目根目录 opencode.json。",
	},
};

export default function ConnectGuidePage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws } = useWorkspaceBySlug(slug);

	const [step, setStep] = useState<1 | 2 | 3>(1);
	const [client, setClient] = useState<McpClientKey>("openclacky");

	// 已有 token 检测（第 2 步提示可跳过）
	const [tokens, setTokens] = useState<McpTokenItem[]>([]);
	const loadedRef = useRef(false);
	useEffect(() => {
		if (!ws || loadedRef.current) return;
		loadedRef.current = true;
		let cancelled = false;
		fetchMyMcpTokens()
			.then((list) => {
				if (!cancelled) setTokens(list);
			})
			.catch(() => {});
		return () => {
			cancelled = true;
		};
	}, [ws]);
	const hasActiveToken = tokens.some((t) => t.status === "active");

	// 第 2 步签发表单
	const [formName, setFormName] = useState("");
	const [submitting, setSubmitting] = useState(false);
	const [issueError, setIssueError] = useState<string | null>(null);
	const [freshToken, setFreshToken] = useState<string | null>(null);
	const [copiedFresh, setCopiedFresh] = useState(false);
	const [copyFreshFailed, setCopyFreshFailed] = useState(false);

	const handleIssue = async () => {
		const name = formName.trim();
		if (!name) return;
		setSubmitting(true);
		setIssueError(null);
		try {
			const { token, plainToken } = await issueMcpToken(name);
			setTokens((prev) => [token, ...prev]);
			setFreshToken(plainToken);
			setCopiedFresh(false);
		} catch (e) {
			setIssueError(e instanceof Error ? e.message : "签发失败");
		} finally {
			setSubmitting(false);
		}
	};

	const hint = INSTALL_HINTS[client];

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>连接引导</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>连接引导</h1>
						<p>三步把 MCP 客户端接入 CGC 2046 平台</p>
					</div>
				</header>

				<ol className="connect-steps" aria-label="连接步骤">
					{STEPS.map((label, index) => {
						const num = index + 1;
						return (
							<li
								key={label}
								className={`connect-steps__item ${
									num === step ? "connect-steps__item--current" : ""
								} ${num < step ? "connect-steps__item--done" : ""}`}
								aria-current={num === step ? "step" : undefined}
							>
								<span className="connect-steps__num">{num}</span>
								{label}
							</li>
						);
					})}
				</ol>

				{step === 1 && (
					<section className="connect-step-card">
						<h2>安装 MCP 客户端</h2>
						<p className="connect-step-card__desc">
							任选一个支持 streamable HTTP 的 MCP 客户端；已安装可跳过本步。
						</p>
						<div className="ws-tabs" role="tablist" aria-label="选择客户端">
							{MCP_CLIENTS.map((c) => (
								<button
									key={c.key}
									type="button"
									role="tab"
									aria-selected={client === c.key}
									className={`ws-tab ${client === c.key ? "ws-tab--selected" : ""}`}
									onClick={() => setClient(c.key)}
								>
									{c.label}
								</button>
							))}
						</div>
						<pre className="l-codeblock mcp-snippet__code">{hint.command}</pre>
						<p className="mcp-snippet__note">{hint.description}</p>
						<div className="connect-step-card__actions">
							<button
								type="button"
								className="join-button join-button--primary"
								onClick={() => setStep(2)}
							>
								下一步
							</button>
						</div>
					</section>
				)}

				{step === 2 && (
					<section className="connect-step-card">
						<h2>生成连接 token</h2>
						{hasActiveToken && !freshToken && (
							<p className="settings-note">
								检测到你已有有效 token，可直接进入下一步在配置中使用它；
								也可以在下方为新设备签发一个。
							</p>
						)}
						{freshToken ? (
							<div className="mcp-token-once" role="status">
								<p>
									连接 token 只显示这一次，请立即复制保存（第 3
									步配置需要用到）：
								</p>
								<div className="mcp-token-once__row">
									<code>{freshToken}</code>
									<button
										type="button"
										className="join-button join-button--outline"
										onClick={() => {
											void copyText(freshToken).then((ok) => {
												if (ok) {
													setCopiedFresh(true);
													setCopyFreshFailed(false);
													setTimeout(() => setCopiedFresh(false), 2000);
												} else {
													setCopyFreshFailed(true);
												}
											});
										}}
									>
										{copiedFresh ? "已复制" : "复制"}
									</button>
								</div>
								{copyFreshFailed && (
									<p className="mcp-copy-error" role="alert">
										复制失败，请手动选择上方 token 文本复制。
									</p>
								)}
							</div>
						) : (
							<div className="invitation-form">
								<label className="join-field">
									<span>备注名称（标识设备或客户端）</span>
									<input
										type="text"
										className="join-input"
										placeholder="如：我的 Mac"
										value={formName}
										onChange={(e) => setFormName(e.target.value)}
										disabled={submitting}
									/>
								</label>
								{issueError && (
									<div className="members-error" role="alert">
										{issueError}
									</div>
								)}
								<button
									type="button"
									className="join-button join-button--primary"
									onClick={handleIssue}
									disabled={submitting || !formName.trim()}
								>
									{submitting ? "签发中…" : "签发"}
								</button>
							</div>
						)}
						<div className="connect-step-card__actions">
							<button
								type="button"
								className="join-button join-button--ghost"
								onClick={() => setStep(1)}
							>
								上一步
							</button>
							<button
								type="button"
								className="join-button join-button--primary"
								onClick={() => setStep(3)}
							>
								下一步
							</button>
						</div>
					</section>
				)}

				{step === 3 && (
					<section className="connect-step-card">
						<h2>拷贝配置</h2>
						<p className="connect-step-card__desc">
							把片段写入对应客户端的配置文件，并将占位符替换为第 2
							步生成的 token。保存后重启客户端即可使用 CGC 平台工具。
						</p>
						<McpConfigSnippet />
						<div className="connect-step-card__actions">
							<button
								type="button"
								className="join-button join-button--ghost"
								onClick={() => setStep(2)}
							>
								上一步
							</button>
							<Link
								href={`/w/${slug}/settings/connection`}
								className="join-button join-button--outline"
							>
								完成，前往连接设置
							</Link>
						</div>
					</section>
				)}
			</div>
		</WorkspaceShell>
	);
}
