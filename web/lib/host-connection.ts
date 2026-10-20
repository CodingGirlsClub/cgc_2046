import { resolveWebBaseUrl } from "./seo";
import { MIN_HOST_VERSION, compareHostVersions } from "./host-version";

/**
 * 课程学习页 ↔ 本机 Host 的连接检测（R26、R28；KTD4、KTD10、KTD15；ADR-0022）。
 *
 * 只产出 R26 的状态，不带文案：文案由对话栏（U10）用自己的 i18n 命名空间给出。
 * 两个入口：
 * - checkHost()：面板挂载、自动轮询时调用。许可未授予且没有「本页曾连上 Host」的证据时只回报状态、不发请求
 *   ——第一次本机请求必须由用户手势发起，浏览器授权提示由那次请求触发。成功连上过一次后证据写入
 *   sessionStorage，刷新页面仍可静默重连，不会反复要授权；明确 denied 时永远不发请求。
 * - requestHostAccess()：只从点击处理器调用；有用户手势，浏览器的本机访问授权提示在这里触发。
 */

declare global {
	interface Navigator {
		/** User-Agent Client Hints：只有 Chromium 实现（Safari、Firefox 没有），lib.dom 未收录 */
		userAgentData?: { platform: string };
	}
	interface RequestInit {
		/** Local Network Access（Chrome 142+）：事先声明目标是本机，浏览器据此弹授权提示 */
		targetAddressSpace?: "loopback" | "local" | "public";
	}
}

/** 与 `cgc-host/protocol.json` 的 `port` 一致（契约测试钉住）；改端口就是改协议 */
export const HOST_PORT = 47823;
export const HOST_HTTP_ORIGIN = `http://127.0.0.1:${HOST_PORT}`;
/** protocol.json 没有约定路径，WebSocket 升级走根路径 */
export const HOST_WS_URL = `ws://127.0.0.1:${HOST_PORT}`;

/**
 * 课程作业目录的显示形态（R15）：与 `cgc-host/src/state.ts` 的 `workDir` 同一棵树——工作区根是终端插件的工作目录，
 * 课程目录在其下单独一层。跨包无编译期共享，契约由 `host-connection.test.ts` 读 Host 源码钉住。
 */
export function courseDir(userId: string, courseId: string): string {
	return `~/cgc2046_workspace/courses/${userId}/${courseId}`;
}

/** KTD15：`/health` 报告的版本低于它，就进入「Host 需要更新」 */
export { MIN_HOST_VERSION } from "./host-version";

/** `/health` 的 agents 条目：本机装了哪些 agent（KTD1）。页面据此决定连不连、给不给选择器 */
export interface HostAgentStatus {
	kind: string;
	present: boolean;
	envError?: string;
	/** 可复用来源（目前只有 Codex 上报）：managed / codex-acp / chatgpt-app / codex-cli；只读，不改路由 */
	sources?: { source: string; version: string | null }[];
}

export type HostConnection =
	| { state: "unsupported"; reason: "browser" }
	| { state: "unsupported"; reason: "address"; canonicalUrl: string }
	| { state: "needsPermission"; probeFailed?: true }
	| { state: "blocked" }
	| { state: "noHost" }
	| { state: "staleHost" }
	/** agents / paired 由对话栏映射到「本机没有可用的 agent」「未配对」，再决定是否打开 WebSocket */
	| { state: "detected"; agents: HostAgentStatus[]; paired: boolean; capabilities: string[] };

/** 浏览器不认 `loopback-network`（Chrome 145 之前）时返回 "unknown"。
 *  不改查旧名 `local-network-access`：老版本 Chrome 查它会让渲染进程崩溃，try/catch 拦不住。 */
async function loopbackPermission(): Promise<PermissionState | "unknown"> {
	try {
		const status = await navigator.permissions.query({
			name: "loopback-network" as PermissionName,
		});
		return status.state;
	} catch {
		return "unknown";
	}
}

/**
 * 「本页曾成功连上 Host」的证据（sessionStorage）：刷新保留、关标签页即失，不含任何凭证或 Host 信息。
 * 用途：Chromium 的 loopback 权限查询在部分版本会一直报 prompt，光凭它分不清「还没授权」与「已授权但
 * 查询不更新」；成功连上过一次说明这台机器上请求实际可达，刷新后允许静默探测一次（自动重连）。
 * 首次访问没有这份证据，仍按 R28 把手势留给用户。
 */
const REACHED_HOST_KEY = "cgc-host-reached";

function rememberReachedHost(): void {
	try {
		window.sessionStorage.setItem(REACHED_HOST_KEY, "1");
	} catch {
		// 隐私模式等取不到存储：少一层记忆，只影响刷新后的自动重连，不影响当前页
	}
}

function reachedHostEvidence(): boolean {
	try {
		return window.sessionStorage.getItem(REACHED_HOST_KEY) === "1";
	} catch {
		return false;
	}
}

/** 连不上、被浏览器拦下、回的不是 Host 的应答（字段缺失时比较版本即抛错），都返回 null */
async function probe(): Promise<HostConnection | null> {
	try {
		const response = await fetch(`${HOST_HTTP_ORIGIN}/health`, {
			targetAddressSpace: "loopback",
		});
		const health = (await response.json()) as {
			version: string;
			ompPresent?: boolean;
			paired: boolean;
			agents?: HostAgentStatus[];
			/** 本机支持的能力（期 2 起有 "agent.install"）；旧 Host 不带，按空数组处理 */
			capabilities?: string[];
		};
		if (compareHostVersions(health.version, MIN_HOST_VERSION) < 0) {
			return { state: "staleHost" };
		}
		// Host 0.1.x 只报 ompPresent（版本门会把它们判成需要更新）；0.2.0 起报 agents
		const agents = health.agents ?? [{ kind: "omp", present: health.ompPresent === true }];
		return { state: "detected", agents, paired: health.paired, capabilities: health.capabilities ?? [] };
	} catch {
		return null;
	}
}

/** 探测拿到 Host 的应答（detected / staleHost 都算）就记下「本页曾连上」的证据：刷新后的自动重连靠它。
 *  旧版 Host 也证明 loopback 请求可达——刷新后仍应显示「Host 需要更新」，而不是退回授权卡。 */
async function probeAndRemember(): Promise<HostConnection | null> {
	const probed = await probe();
	if (probed) rememberReachedHost();
	return probed;
}

async function detect(fromUserGesture: boolean, previouslyReachedHost = false): Promise<HostConnection> {
	// Host 只认构建时写死的唯一来源（KTD4）；换个地址打开（127.0.0.1、预览域名）一律连不上
	const canonicalOrigin = new URL(resolveWebBaseUrl()).origin;
	if (location.origin !== canonicalOrigin) {
		return {
			state: "unsupported",
			reason: "address",
			canonicalUrl: `${canonicalOrigin}${location.pathname}${location.search}${location.hash}`,
		};
	}

	// ADR-0022：支持 macOS、Windows 与 Linux 桌面上的 Chrome，以及桌面版 Firefox。
	// 引擎判定用 userAgentData（UA Client Hints，只有 Chromium 实现；Safari 有 permissions API
	// 但同样没有它，故一并排除）。桌面 Firefox 没有浏览器级回环权限模型（无提示、无需手势），
	// 单独走「直接探测」路径：可达即 detected，不可达即 noHost，不出现「需要授权」的假状态。
	const chromiumPlatform = navigator.userAgentData?.platform;
	const chromeDesktop = chromiumPlatform !== undefined && ["macOS", "Windows", "Linux"].includes(chromiumPlatform) && !!navigator.permissions;
	const firefoxDesktop =
		chromiumPlatform === undefined && /Firefox\//.test(navigator.userAgent) && !/Android|Mobile/.test(navigator.userAgent);
	if (!chromeDesktop && !firefoxDesktop) {
		return { state: "unsupported", reason: "browser" };
	}
	if (firefoxDesktop) {
		const probed = await probeAndRemember();
		return probed ?? { state: "noHost" };
	}

	// 权限查询不是「请求会不会被拦」的可靠信号：Chromium 142–154 都可能一直报 prompt，但请求实际可达。
	// 首次访问（没有「本页曾连上」的证据）仍把手势留给用户——浏览器的授权提示由那次带手势的请求触发；
	// 有证据（本轮成功过，或刷新后从 sessionStorage 读到）才允许无手势静默探测，用于自动重连。
	const hasEvidence = previouslyReachedHost || reachedHostEvidence();
	if (!fromUserGesture) {
		const permission = await loopbackPermission();
		if (permission === "denied") return { state: "blocked" };
		if (permission !== "granted" && !hasEvidence) return { state: "needsPermission" };
	}

	const probed = await probeAndRemember();
	if (probed) return probed;

	// 被拒的失败是静默的（WebSocket 只见 close code 1006），只能回头问授权状态：
	// 只有明确 denied 才判定被阻止；prompt / unknown 无法区分权限未获批和 Host 未运行。
	// 这里只认本轮「真的连上过」的证据：sessionStorage 的旧证据只用于打开静默探测，探测失败时仍按
	// 权限状态要求授权——避免把「权限被收回」误报成「没有 Host」。
	const permission = await loopbackPermission();
	if (permission === "denied") return { state: "blocked" };
	if (permission !== "granted" && !previouslyReachedHost) return { state: "needsPermission", probeFailed: true };
	return { state: "noHost" };
}

/** 本页曾成功探测到 Host 时（本轮成功过，或刷新后从 sessionStorage 读到证据），即使浏览器不认权限名
 * 或一直报告 prompt，也可重连；明确 denied 仍优先阻止请求。不查询可能导致旧版 Chromium 崩溃的旧权限名。 */
export function checkHost({ previouslyReachedHost = false }: { previouslyReachedHost?: boolean } = {}): Promise<HostConnection> {
	return detect(false, previouslyReachedHost);
}

export function requestHostAccess(): Promise<HostConnection> {
	return detect(true);
}
