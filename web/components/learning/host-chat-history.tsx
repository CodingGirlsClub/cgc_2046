"use client";

/**
 * 历史对话下拉（Session History）：列出本课程的历史会话（时间 + 消息数），点选切换。
 *
 * - 只在 Host 协议 v2+ 显示（旧 Host 不认识 chat.sessions，入口整体隐藏，功能优雅降级）。
 * - 列表失败与切换失败都就地呈现，不打扰正在进行的对话；切换成功后由 useHostChat 的
 *   history 归约接管（下拉关闭）。
 * - 点面板与按钮以外的地方关闭；每次打开都重新拉列表，跨过「新开对话」后「当前」不会滞留。
 * - 有回合在跑或未持有（!canSend）时行不可点；当前会话行标注且不可重复点。
 */

import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { formatDateTime } from "@/lib/format";
import type { ChatErrorCode, HostChat } from "./use-host-chat";

interface HistoryState {
	rows: { sessionId: string; updatedAt: string | null; messageCount: number | null }[];
	current: string | null;
	nextCursor: string | null;
	loading: boolean;
	loadingMore: boolean;
	error: ChatErrorCode | null;
}

export default function HostChatHistory({ chat }: { chat: HostChat }) {
	const t = useTranslations("hostChat.history");
	const tAgent = useTranslations("hostChat.agent");
	const [open, setOpen] = useState(false);
	const [state, setState] = useState<HistoryState | null>(null);
	const panelRef = useRef<HTMLDivElement>(null);
	const buttonRef = useRef<HTMLButtonElement>(null);
	// 点面板与按钮以外的地方关闭：覆盖「开着下拉又去点了新开对话」这类情况，重新打开时列表与「当前」一起刷新
	useEffect(() => {
		if (!open) return;
		const onMouseDown = (event: MouseEvent) => {
			const target = event.target as Node;
			if (panelRef.current?.contains(target) || buttonRef.current?.contains(target)) return;
			setOpen(false);
		};
		document.addEventListener("mousedown", onMouseDown);
		return () => document.removeEventListener("mousedown", onMouseDown);
	}, [open]);
	// 旧版 Host：协议里没有 chat.sessions，不显示入口
	if ((chat.pairing.status?.protocolVersion ?? 0) < 2) return null;

	/** 装好 ≥2 个 agent 时列出 chips：与标题行的选择器是同一份状态（点它就是切 agent） */
	const agentNames: Record<string, string> = { omp: "OMP", codex: "Codex" };
	const presentAgents = chat.agents.filter((agent) => agent.present);

	async function load(cursor?: string) {
		setState((prev) => ({
			rows: prev?.rows ?? [],
			current: prev?.current ?? null,
			nextCursor: prev?.nextCursor ?? null,
			loading: !cursor,
			loadingMore: !!cursor,
			error: null,
		}));
		const result = await chat.listSessions(cursor);
		setState((prev) => {
			const base: HistoryState = prev ?? { rows: [], current: null, nextCursor: null, loading: false, loadingMore: false, error: null };
			if ("error" in result) return { ...base, loading: false, loadingMore: false, error: result.error };
			return {
				rows: cursor ? [...base.rows, ...result.sessions] : result.sessions,
				current: result.current,
				nextCursor: result.nextCursor,
				loading: false,
				loadingMore: false,
				error: null,
			};
		});
	}

	function toggle() {
		if (!open) void load();
		setOpen((prev) => !prev);
	}

	async function switchTo(sessionId: string) {
		const result = await chat.openSession(sessionId);
		if (result.ok) setOpen(false); // history 归约已接管切换
		else setState((prev) => (prev ? { ...prev, error: result.code } : prev));
	}

	const errorText = (code: ChatErrorCode) =>
		code === "session_unavailable" ? t("unavailable") : code === "busy" ? t("busy") : t("failed");

	return (
		<>
			<button ref={buttonRef} type="button" className="learning-chat__text-button" aria-expanded={open} onClick={toggle}>
				{t("title")}
			</button>
			{open ? (
				<div ref={panelRef} className="learning-chat__history">
					{presentAgents.length > 1 ? (
						<div className="learning-chat__history-agents" role="group" aria-label={tAgent("switch")}>
							{presentAgents.map((agent) => (
								<button
									key={agent.kind}
									type="button"
									className="learning-chat__option"
									aria-pressed={agent.kind === chat.agent}
									disabled={!chat.canSend}
									onClick={() => {
										setOpen(false);
										chat.chooseAgent(agent.kind);
									}}
								>
									{agentNames[agent.kind] ?? agent.kind}
								</button>
							))}
						</div>
					) : null}
					{state?.loading ? <p className="learning-chat__hint">{t("loading")}</p> : null}
					{state?.error ? (
						<p role="status" className="learning-chat__note">
							{errorText(state.error)}
						</p>
					) : null}
					{state && !state.loading && !state.error && state.rows.length === 0 ? <p className="learning-chat__hint">{t("empty")}</p> : null}
					{state?.rows.map((row) => {
						const current = row.sessionId === state.current;
						return (
							<button
								key={row.sessionId}
								type="button"
								className="learning-chat__history-item"
								disabled={current || !chat.canSend || state.loadingMore}
								onClick={() => void switchTo(row.sessionId)}
							>
								<span>{t("entry", { time: row.updatedAt ? formatDateTime(row.updatedAt) : "—", count: row.messageCount ?? 0 })}</span>
								{current ? <span className="learning-chat__history-mark">{t("current")}</span> : null}
							</button>
						);
					})}
					{state?.nextCursor ? (
						<button
							type="button"
							className="learning-chat__text-button"
							disabled={state.loadingMore}
							onClick={() => void load(state.nextCursor ?? undefined)}
						>
							{t("more")}
						</button>
					) : null}
				</div>
			) : null}
		</>
	);
}
