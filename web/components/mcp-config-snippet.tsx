"use client";

/**
 * MCP 客户端配置片段 Tab 组件（切片 D #44，D-D10）。
 *
 * OpenClacky / omp / opencode 三 Tab：占位符片段 + 复制按钮 + 存放路径与
 * 占位符说明。片段由 buildConfigSnippet 纯函数生成（绝不含明文 token）。
 * 连接设置页（/w/[slug]/settings/connection）与连接引导页（/w/[slug]/connect）共用。
 */

import { useState } from "react";
import {
	MCP_CLIENTS,
	buildConfigSnippet,
	type McpClientKey,
} from "@/lib/mcp";
import { copyText } from "@/lib/clipboard";

export default function McpConfigSnippet() {
	const [active, setActive] = useState<McpClientKey>("openclacky");
	const [copied, setCopied] = useState(false);
	const [copyFailed, setCopyFailed] = useState(false);
	const info = MCP_CLIENTS.find((c) => c.key === active) ?? MCP_CLIENTS[0];
	const snippet = buildConfigSnippet(info.key);

	return (
		<div className="mcp-snippet">
			<div className="ws-tabs" role="tablist" aria-label="选择 MCP 客户端">
				{MCP_CLIENTS.map((c) => (
					<button
						key={c.key}
						type="button"
						role="tab"
						aria-selected={active === c.key}
						className={`ws-tab ${active === c.key ? "ws-tab--selected" : ""}`}
						onClick={() => {
							setActive(c.key);
							setCopied(false);
							setCopyFailed(false);
						}}
					>
						{c.label}
					</button>
				))}
			</div>
			<div className="mcp-snippet__body">
				<div className="mcp-snippet__meta">
					<span>
						写入 <code>{info.configPath}</code>
					</span>
					<button
						type="button"
						className="join-button join-button--outline"
						onClick={() => {
							void copyText(snippet).then((ok) => {
								if (ok) {
									setCopied(true);
									setCopyFailed(false);
									setTimeout(() => setCopied(false), 2000);
								} else {
									setCopyFailed(true);
								}
							});
						}}
					>
						{copied ? "已复制" : "复制配置"}
					</button>
				</div>
				{copyFailed && (
					<p className="mcp-copy-error" role="alert">
						复制失败，请手动选择下方文本复制。
					</p>
				)}
				<pre className="l-codeblock mcp-snippet__code">{snippet}</pre>
				<p className="mcp-snippet__note">{info.note}</p>
			</div>
		</div>
	);
}
