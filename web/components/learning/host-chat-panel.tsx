"use client";

/**
 * 课程学习页的对话栏（U10；R7–R9、R12–R15、R19、R20、R26–R29；ADR-0022）：与学员本机 Host 驱动的 OMP 对话。
 *
 * 状态与动作全部来自 useHostChat；这里只按状态给出文案与下一步。agent 的文字、思考、工具输入输出、卡片内容
 * 一律是 React 文本节点：不解析 Markdown、不生成链接，HTML 与 javascript: 链接原样显示为文字。
 */

import { useEffect, useRef, useState, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import { copyText } from "@/lib/clipboard";
import HostChatCard from "./host-chat-cards";
import HostPairingList from "./host-pairing-list";
import type { PairingErrorReason } from "./use-host-pairing";
import { useHostChat, type ChatEvent, type HostChat } from "./use-host-chat";

/** 安装与更新同一条命令（U7）：install.sh 覆盖安装即更新 */
const INSTALL_COMMAND = "curl -fsSL https://api.codingirlsclub.com/ext/cgc-host/install.sh | bash";

const PAIRING_ERROR_KEYS: Record<PairingErrorReason, string> = {
	busy: "pairingError.busy",
	invalid_token: "pairingError.invalidToken",
	platform_unavailable: "pairingError.platformUnavailable",
	not_paired: "pairingError.notPaired",
	timeout: "pairingError.timeout",
	disconnected: "pairingError.disconnected",
	token_limit: "pairingError.tokenLimit",
	failed: "pairingError.failed",
};

/** 对话方法的 error.params.code（cgc-host/AGENTS.md）；其余归「出错了，请重试」 */
const CHAT_ERROR_KEYS: Record<string, string> = {
	chat_unavailable: "error.chatUnavailable",
	busy: "error.busy",
	timeout: "error.timeout",
};

function CommandCard() {
	const t = useTranslations("hostChat.command");
	/** null：还没复制 */
	const [copied, setCopied] = useState<boolean | null>(null);
	return (
		<div className="learning-chat__command">
			<pre>
				<code>{INSTALL_COMMAND}</code>
			</pre>
			<button type="button" className="learning-chat__option" onClick={() => void copyText(INSTALL_COMMAND).then(setCopied)}>
				{copied ? t("copied") : t("copy")}
			</button>
			{copied === false ? (
				<p role="alert" className="learning-chat__note">
					{t("copyFailed")}
				</p>
			) : null}
		</div>
	);
}

function Notice({ title, hint, children }: { title: string; hint?: string; children?: ReactNode }) {
	return (
		<div className="learning-chat__state">
			<strong>{title}</strong>
			{hint ? <p className="learning-chat__hint">{hint}</p> : null}
			{children}
		</div>
	);
}

/** R26：对话以外的每种连接状态，给出说明与下一步 */
function StateMessage({ chat }: { chat: HostChat }) {
	const t = useTranslations("hostChat.state");
	const tPairing = useTranslations("hostChat");
	const { view, pairing } = chat;
	const button = (label: string, onClick: () => void) => (
		<button type="button" className="learning-chat__primary" onClick={onClick}>
			{label}
		</button>
	);
	switch (view.state) {
		case "unsupported":
			return view.reason === "browser" ? (
				<Notice title={t("unsupportedBrowser")} hint={t("unsupportedBrowserHint")} />
			) : (
				<Notice title={t("unsupportedAddress")}>
					<a href={view.canonicalUrl} className="learning-chat__link">
						{t("openCanonical")}
					</a>
				</Notice>
			);
		case "needsPermission":
			return (
				<Notice title={t("needsPermission")} hint={t("needsPermissionHint")}>
					{button(t("allowAccess"), chat.requestAccess)}
				</Notice>
			);
		case "staleHost":
			return (
				<Notice title={t("staleHost")} hint={t("staleHostHint")}>
					<CommandCard />
				</Notice>
			);
		case "noHost":
			return (
				<Notice title={t("noHost")} hint={t("noHostHint")}>
					<CommandCard />
					<p className="learning-chat__hint">{t("loginItemsHint")}</p>
				</Notice>
			);
		case "blocked":
			return <Notice title={t("blocked")} hint={t("blockedHint")} />;
		case "noOmp":
			return <Notice title={t("noOmp")} hint={t("noOmpHint")} />;
		case "unpaired":
			return <Notice title={t("unpaired")}>{button(t("connect"), () => void pairing.connect())}</Notice>;
		case "confirming":
			return (
				<Notice title={t("confirming")}>
					<button type="button" className="learning-chat__option" onClick={pairing.cancel}>
						{t("cancel")}
					</button>
				</Notice>
			);
		case "denied":
			return <Notice title={t("denied")}>{button(t("retry"), () => void pairing.connect())}</Notice>;
		case "pairingFailed":
			return (
				<Notice title={tPairing(PAIRING_ERROR_KEYS[view.reason])}>{button(t("retry"), () => void pairing.connect())}</Notice>
			);
		case "disconnected":
			return <Notice title={t("disconnected")} />;
		default:
			return (
				<p role="status" className="learning-chat__hint">
					{t("checking")}
				</p>
			);
	}
}

function ToolStep({ step }: { step: Extract<ChatEvent, { kind: "tool" }> }) {
	const t = useTranslations("hostChat.toolStatus");
	return (
		<details className="learning-chat__fold learning-chat__tool">
			<summary>
				<span className={`learning-chat__tool-dot learning-chat__tool-dot--${step.status}`} aria-hidden="true" />
				<span className="learning-chat__tool-title">{step.title || step.toolKind}</span>
				<span className="learning-chat__tool-status">{t(step.status)}</span>
			</summary>
			{step.input ? <pre>{step.input}</pre> : null}
			{step.output ? <pre>{step.output}</pre> : null}
		</details>
	);
}

/** 一轮的结尾：R27 的模型错误说明，或停止、异常结束的提示 */
function EndNote({ end, raw }: { end: Extract<ChatEvent, { kind: "end" }>; raw: string }) {
	const t = useTranslations("hostChat");
	if (end.modelError === "auth" || end.modelError === "quota") {
		return (
			<div role="alert" className="learning-chat__alert">
				<strong>{t(end.modelError === "auth" ? "modelError.authTitle" : "modelError.quotaTitle")}</strong>
				<p>{t(end.modelError === "auth" ? "modelError.authHint" : "modelError.quotaHint")}</p>
				{raw ? (
					<details className="learning-chat__fold">
						<summary>{t("modelError.raw")}</summary>
						<pre>{raw}</pre>
					</details>
				) : null}
			</div>
		);
	}
	if (end.modelError === "unknown") return <p className="learning-chat__note">{t("modelError.unknownHint")}</p>;
	if (end.stopReason === "cancelled") return <p className="learning-chat__note">{t("end.cancelled")}</p>;
	if (end.stopReason === "error") return <p className="learning-chat__note">{t("end.error")}</p>;
	return null;
}

/** 按学员的消息切成回合：一轮的结尾带 auth / quota 时，这一轮 agent 的文字其实是模型报错，改为说明，原文折叠在说明里 */
function Turn({ events }: { events: ChatEvent[] }) {
	const t = useTranslations("hostChat");
	const end = events.find((event) => event.kind === "end");
	const misconfigured = end?.kind === "end" && (end.modelError === "auth" || end.modelError === "quota");
	const raw = misconfigured ? events.map((event) => (event.kind === "message" ? event.text : "")).join("") : "";
	return events.map((event, index) => {
		switch (event.kind) {
			case "user":
				return (
					<p key={index} className="learning-chat__user">
						{event.text}
					</p>
				);
			case "message":
				return misconfigured ? null : (
					<p key={index} className="learning-chat__message">
						{event.text}
					</p>
				);
			case "thought":
				return (
					<details key={index} className="learning-chat__fold">
						<summary>{t("thought")}</summary>
						<p>{event.text}</p>
					</details>
				);
			case "tool":
				return <ToolStep key={event.toolCallId} step={event} />;
			case "end":
				return <EndNote key={index} end={event} raw={raw} />;
		}
	});
}

function Conversation({ chat, workDir }: { chat: HostChat; workDir: string }) {
	const t = useTranslations("hostChat");
	const [draft, setDraft] = useState("");
	const logRef = useRef<HTMLDivElement>(null);

	// 流式回复跟到底部
	const last = chat.events.at(-1);
	useEffect(() => {
		const log = logRef.current;
		if (log) log.scrollTop = log.scrollHeight;
	}, [last, chat.cards.length]);

	const turns: ChatEvent[][] = [];
	for (const event of chat.events) {
		if (event.kind === "user" || turns.length === 0) turns.push([event]);
		else turns[turns.length - 1].push(event);
	}
	const errorKey = chat.error ? (CHAT_ERROR_KEYS[chat.error] ?? "error.failed") : null;

	async function submit() {
		if (await chat.send(draft)) setDraft("");
	}

	return (
		<>
			{chat.view.state === "evicted" ? (
				<div className="learning-chat__banner" role="status">
					<span>{t("state.evicted")}</span>
					<button type="button" className="learning-chat__option" onClick={chat.reclaim}>
						{t("state.reclaim")}
					</button>
				</div>
			) : null}
			<div ref={logRef} className="learning-chat__body" role="log" aria-label={t("logLabel")}>
				{!chat.attached ? (
					errorKey ? (
						<div className="learning-chat__state">
							<p role="alert">{t(errorKey)}</p>
							<button type="button" className="learning-chat__option" onClick={chat.reclaim}>
								{t("retry")}
							</button>
						</div>
					) : (
						<p role="status" className="learning-chat__hint">
							{t("attaching")}
						</p>
					)
				) : chat.events.length === 0 ? (
					<p className="learning-chat__hint">{t("empty")}</p>
				) : (
					turns.map((events, index) => <Turn key={index} events={events} />)
				)}
			</div>
			{chat.cards.map((card) => (
				<HostChatCard key={card.cardId} card={card} onAnswer={(answer) => chat.answer(card.cardId, answer)} />
			))}
			<form
				className="learning-chat__composer"
				onSubmit={(e) => {
					e.preventDefault();
					void submit();
				}}
			>
				{chat.attached && errorKey ? (
					<p role="alert" className="learning-chat__note">
						{t(errorKey)}
					</p>
				) : null}
				<textarea
					aria-label={t("inputLabel")}
					placeholder={t("placeholder")}
					value={draft}
					onChange={(e) => setDraft(e.target.value)}
					onKeyDown={(e) => {
						// Enter 发送、Shift+Enter 换行；输入法选词时的 Enter 不算
						if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
							e.preventDefault();
							void submit();
						}
					}}
				/>
				<div className="learning-chat__composer-row">
					<span className="learning-chat__workdir" title={workDir}>
						{t("workDir", { path: workDir })}
					</span>
					{chat.running ? (
						<button type="button" className="learning-chat__option" disabled={chat.stopping} onClick={chat.stop}>
							{chat.stopping ? t("stopping") : t("stop")}
						</button>
					) : (
						<button type="submit" className="learning-chat__primary" disabled={!chat.canSend || !draft.trim()}>
							{t("send")}
						</button>
					)}
				</div>
			</form>
		</>
	);
}

export default function HostChatPanel(props: {
	courseId: string;
	userId: string;
	locale: string;
	workspaceId: string;
	/** 页面显示的课程版本号，未知为 null */
	courseVersion: number | null;
	/** 学员正在看的单元 id，总览为 null */
	unitId: string | null;
}) {
	const t = useTranslations("hostChat");
	const chat = useHostChat(props);
	const [showComputers, setShowComputers] = useState(false);
	const conversation = chat.view.state === "ready" || chat.view.state === "evicted";
	return (
		<aside className="learning-chat" aria-label={t("title")}>
			<header className="learning-chat__head">
				<h2>{t("title")}</h2>
				<div className="learning-chat__head-actions">
					{conversation ? (
						<button
							type="button"
							className="learning-chat__text-button"
							disabled={!chat.canSend}
							onClick={chat.newChat}
						>
							{t("newChat")}
						</button>
					) : null}
					<button
						type="button"
						className="learning-chat__text-button"
						aria-expanded={showComputers}
						onClick={() => setShowComputers((open) => !open)}
					>
						{t("computers")}
					</button>
				</div>
			</header>
			{showComputers ? (
				<div className="learning-chat__computers">
					<HostPairingList currentTokenId={chat.pairing.status?.tokenId ?? null} onRevokeCurrent={chat.pairing.forget} />
				</div>
			) : null}
			{conversation ? (
				// R15：这门课的作业目录（Host 按账号与课程建在学员电脑上）
				<Conversation chat={chat} workDir={`~/CGC/${props.userId}/${props.courseId}`} />
			) : (
				<div className="learning-chat__body">
					<StateMessage chat={chat} />
				</div>
			)}
		</aside>
	);
}
