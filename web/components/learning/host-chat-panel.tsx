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
import HostChatHistory from "./host-chat-history";
import HostPairingList from "./host-pairing-list";
import { SafeMarkdown } from "./material-renderer";
import { courseDir } from "@/lib/host-connection";
import type { PairingErrorReason } from "./use-host-pairing";
import { useHostChat, type ChatEvent, type HostChat, type HostChatSetting } from "./use-host-chat";

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

/** agent 的显示名：Host 只报 kind（KTD1），名字属于页面文案 */
const AGENT_NAMES: Record<string, string> = { omp: "OMP", codex: "Codex" };
const agentName = (kind: string) => AGENT_NAMES[kind] ?? kind;

/** 期 1 是 BYO：适配器由学员自己装（Host 只探测）。这条命令装了 Bun 就有——Host 安装时已经保证 Bun 在 PATH 上 */
const CODEX_ACP_INSTALL = "bun add -g @agentclientprotocol/codex-acp";

/** 对话方法的 error.params.code（cgc-host/AGENTS.md）；其余归「出错了，请重试」 */
const CHAT_ERROR_KEYS: Record<string, string> = {
	chat_unavailable: "error.chatUnavailable",
	busy: "error.busy",
	timeout: "error.timeout",
};

/** 安装失败的 code → 下一步：只有网络类才引导「检查网络」，其余有各自的处置 */
const INSTALL_ERROR_KEYS: Record<string, string> = {
	busy: "installFailedBusy",
	timeout: "installFailedTimeout",
	version_mismatch: "installFailedVersion",
	unsupported: "installFailedUnsupported",
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
/** 支持的 agent 与安装状态（期 1 BYO）+「重新检测」：noAgent 视图与「添加 agent」共用同一块 */
function AgentInstall({ chat }: { chat: HostChat }) {
	const t = useTranslations("hostChat.agent");
	const [checking, setChecking] = useState(false);
	const omp = chat.agents.find((agent) => agent.kind === "omp");
	const codex = chat.agents.find((agent) => agent.kind === "codex");
	/** 期 2：Host 声明了安装能力就给「一键安装」；没声明（0.2.0 这类旧 Host）只有手动命令 */
	const canInstall = codex && !codex.present && chat.capabilities.includes("agent.install");
	const installing = chat.install === "installing";
	const failure = chat.install && chat.install !== "installing" ? chat.install.error : null;
	return (
		<div className="learning-chat__agents">
			<p className="learning-chat__hint">{t("ompInstall")}</p>
			<p className="learning-chat__note">{`OMP：${omp?.present ? t("installed") : t("missing")}`}</p>
			{canInstall ? (
				<>
					<button type="button" className="learning-chat__option" disabled={installing} onClick={() => void chat.installAgent()}>
						{installing ? t("installing") : t("installCodex")}
					</button>
					<p className="learning-chat__hint">{installing ? t("installHintRunning") : t("installHint")}</p>
					{failure ? (
						<p className="learning-chat__note" role="alert">
							{t(INSTALL_ERROR_KEYS[failure] ?? "installFailed")}
						</p>
					) : null}
					<p className="learning-chat__hint">{t("codexInstallManual")}</p>
				</>
			) : (
				<p className="learning-chat__hint">{t("codexInstall")}</p>
			)}
			<pre>
				<code>{CODEX_ACP_INSTALL}</code>
			</pre>
			<p className="learning-chat__note">{`Codex：${codex?.present ? t("installed") : t("missing")}`}</p>
			<button
				type="button"
				className="learning-chat__option"
				disabled={checking}
				onClick={() => {
					setChecking(true);
					void chat.refreshAgents().finally(() => setChecking(false));
				}}
			>
				{t("recheck")}
			</button>
		</div>
	);
}

/** R1、R2：装好 ≥2 个 agent 时给选择器；只有 1 个时是静态标签 +「添加 agent」；一个都没有时由 noAgent 视图接管 */
function AgentPicker({ chat }: { chat: HostChat }) {
	const t = useTranslations("hostChat.agent");
	const [open, setOpen] = useState(false);
	const present = chat.agents.filter((agent) => agent.present);
	if (present.length === 0) return null;
	const current = present.some((agent) => agent.kind === chat.agent) ? chat.agent : present[0].kind;
	const label = t("label", { name: agentName(current) });

	if (present.length === 1) {
		return (
			<span className="learning-chat__agent">
				<span className="learning-chat__agent-label">{label}</span>
				<button type="button" className="learning-chat__text-button" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
					{t("add")}
				</button>
				{open ? (
					<div className="learning-chat__agent-menu">
						<AgentInstall chat={chat} />
					</div>
				) : null}
			</span>
		);
	}
	return (
		<span className="learning-chat__agent">
			<button type="button" className="learning-chat__text-button" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
				{label}
			</button>
			{open ? (
				<div className="learning-chat__agent-menu" role="menu">
					{present.map((agent) => (
						<button
							key={agent.kind}
							type="button"
							role="menuitemradio"
							aria-checked={agent.kind === current}
							disabled={!chat.canSend}
							className="learning-chat__option"
							onClick={() => {
								setOpen(false);
								chat.chooseAgent(agent.kind);
							}}
						>
							{agentName(agent.kind)}
						</button>
					))}
					<p className="learning-chat__hint">{t("switchHint")}</p>
					<AgentInstall chat={chat} />
				</div>
			) : null}
		</span>
	);
}

/**
 * 登录卡（KTD4、R6）：只列页面能真正走完的方式——Codex 适配器的 api-key 分支要的是 `_meta.apiKey` 或
 * `OPENAI_API_KEY`，页面没有安全收集并转交密钥的契约，所以首期只开放 ChatGPT 登录（学员自己的账号）。
 */
function HostChatLogin({ chat }: { chat: HostChat }) {
	const t = useTranslations("hostChat.login");
	const [busy, setBusy] = useState(false);
	const [failed, setFailed] = useState(false);
	const chatgpt = chat.login?.find((method) => method.id === "chat-gpt");
	return (
		<div className="learning-chat__login" role="status">
			<p>{t("title", { name: agentName(chat.agent) })}</p>
			{chatgpt ? (
				<button
					type="button"
					className="learning-chat__primary"
					disabled={busy}
					onClick={() => {
						setBusy(true);
						setFailed(false);
						void chat.authenticate(chatgpt.id).then((result) => {
							setBusy(false);
							setFailed(!result.ok);
						});
					}}
				>
					{t("chatgpt")}
				</button>
			) : (
				// 页面拿不到可走完的登录方式（例如只播报 api-key）：给出页面外的做法，并允许重新接一次
				<>
					<p className="learning-chat__note">{t("manual")}</p>
					<button type="button" className="learning-chat__option" onClick={chat.reclaim}>
						{t("retry")}
					</button>
				</>
			)}
			{chatgpt ? <p className="learning-chat__hint">{t("hint")}</p> : null}
			{failed ? (
				<p role="alert" className="learning-chat__note">
					{t("failed")}
				</p>
			) : null}
		</div>
	);
}

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
					{view.probeFailed ? <p role="status" className="learning-chat__note">{t("accessProbeFailed")}</p> : null}
					<strong>{t("notInstalled")}</strong>
					<p className="learning-chat__hint">{t("installBeforeAccess")}</p>
					<CommandCard />
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
		case "noAgent":
			return (
				<Notice title={t("noAgent")} hint={t("noAgentHint")}>
					<AgentInstall chat={chat} />
				</Notice>
			);
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
				// agent 的回复按讲义同一套安全 Markdown 渲染（含公式）；学员消息、思考与工具输出仍是纯文本
				return misconfigured ? null : (
					<div key={index} className="learning-chat__message learning-material--markdown">
						<SafeMarkdown>{event.text}</SafeMarkdown>
					</div>
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

/** 模型选项多（实测 69 个）：按 provider 分组展示；选项值是 `provider/model` 形状 */
function groupByProvider(options: HostChatSetting["options"]) {
	const groups = new Map<string, HostChatSetting["options"]>();
	for (const option of options) {
		const provider = option.value.split("/")[0] || option.value;
		const list = groups.get(provider);
		if (list) list.push(option);
		else groups.set(provider, [option]);
	}
	return [...groups];
}

/** R18 修订：学员可在对话栏按会话改本机 OMP 的模型与思考等级（与发送按钮同排，作业目录另起一行）；Host 或 OMP 不给可选项时（旧版本）整块不渲染 */
function ChatSettings({ chat }: { chat: HostChat }) {
	const t = useTranslations("hostChat");
	/** 改一次要等 OMP 回包：期间禁用两个下拉，避免与回包赛跑 */
	const [pending, setPending] = useState(false);
	const [failure, setFailure] = useState<string | null>(null);

	const errorText = (code: string) => {
		switch (code) {
			case "unknown_method":
				return t("settings.staleHost");
			case "busy":
				return t("settings.busy");
			case "chat_unavailable":
				return t("settings.unavailable");
			default:
				return t("settings.failed");
		}
	};

	const change = async (configId: string, value: string) => {
		setPending(true);
		setFailure(null);
		const result = await chat.setSetting(configId, value);
		setPending(false);
		if (!result.ok) setFailure(errorText(result.code));
	};

	if (chat.settings.length === 0) return null;
	return (
		<>
			<div className="learning-chat__settings">
				{chat.settings.map((option) => (
					<select
						key={option.id}
						className="learning-chat__setting"
						aria-label={option.id === "model" ? t("settings.model") : option.id === "thinking" ? t("settings.thinking") : option.name}
						value={option.currentValue}
						disabled={pending || chat.running}
						onChange={(event) => void change(option.id, event.target.value)}
					>
						{option.id === "model"
							? groupByProvider(option.options).map(([provider, options]) => (
									<optgroup key={provider} label={provider}>
										{options.map((value) => (
											<option key={value.value} value={value.value}>
												{value.name}
											</option>
										))}
									</optgroup>
								))
							: option.options.map((value) => (
									<option key={value.value} value={value.value}>
										{value.name}
									</option>
								))}
					</select>
				))}
			</div>
			{failure ? (
				<p role="alert" className="learning-chat__note">
					{failure}
				</p>
			) : null}
		</>
	);
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
			{chat.login ? <HostChatLogin chat={chat} /> : null}
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
					<ChatSettings chat={chat} />
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
				<span className="learning-chat__workdir" title={workDir}>
					{t("workDir", { path: workDir })}
				</span>
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
					{conversation ? <AgentPicker chat={chat} /> : null}
					{conversation ? <HostChatHistory chat={chat} /> : null}
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
				// R15：这门课的作业目录（Host 按账号与课程建在学员电脑上；路径形态与 Host 的 workDir 同源，见 lib/host-connection.ts）
				<Conversation chat={chat} workDir={courseDir(props.userId, props.courseId)} />
			) : (
				<div className="learning-chat__body">
					<StateMessage chat={chat} />
				</div>
			)}
		</aside>
	);
}
