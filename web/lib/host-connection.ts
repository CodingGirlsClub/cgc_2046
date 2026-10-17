import { resolveWebBaseUrl } from "./seo";
import { MIN_HOST_VERSION, compareHostVersions } from "./host-version";

/**
 * 课程学习页 ↔ 本机 Host 的连接检测（R26、R28；KTD4、KTD10、KTD15；ADR-0022）。
 *
 * 只产出 R26 的状态，不带文案：文案由对话栏（U10）用自己的 i18n 命名空间给出。
 * 两个入口，区别只在「未授权时发不发本机请求」：
 * - checkHost()：页面加载、自动重连时调用。本机访问未授权且没有本页成功探测证据时只回报状态，不发请求。
 * - requestHostAccess()：只从点击处理器调用。第一次本机请求必须由用户手势发起，
 *   浏览器的本机访问授权提示由这次请求触发。
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
}

export type HostConnection =
	| { state: "unsupported"; reason: "browser" }
	| { state: "unsupported"; reason: "address"; canonicalUrl: string }
	| { state: "needsPermission"; probeFailed?: true }
	| { state: "blocked" }
	| { state: "noHost" }
	| { state: "staleHost" }
	/** agents / paired 由对话栏映射到「本机没有可用的 agent」「未配对」，再决定是否打开 WebSocket */
	| { state: "detected"; agents: HostAgentStatus[]; paired: boolean };

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
		};
		if (compareHostVersions(health.version, MIN_HOST_VERSION) < 0) {
			return { state: "staleHost" };
		}
		// Host 0.1.x 只报 ompPresent（版本门会把它们判成需要更新）；0.2.0 起报 agents
		const agents = health.agents ?? [{ kind: "omp", present: health.ompPresent === true }];
		return { state: "detected", agents, paired: health.paired };
	} catch {
		return null;
	}
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
		const probed = await probe();
		return probed ?? { state: "noHost" };
	}

	if (!fromUserGesture) {
		const permission = await loopbackPermission();
		if (permission === "denied") return { state: "blocked" };
		if (permission !== "granted" && !previouslyReachedHost) return { state: "needsPermission" };
	}

	const probed = await probe();
	if (probed) return probed;

	// 被拒的失败是静默的（WebSocket 只见 close code 1006），只能回头问授权状态：
	// 只有明确 denied 才判定被阻止；prompt / unknown 无法区分权限未获批和 Host 未运行。
	const permission = await loopbackPermission();
	if (permission === "denied") return { state: "blocked" };
	if (permission !== "granted" && !previouslyReachedHost) return { state: "needsPermission", probeFailed: true };
	return { state: "noHost" };
}

/** 本页曾成功探测到 Host 时，即使浏览器不认权限名或一直报告 prompt，也可重连；明确 denied 仍优先阻止请求。
 * 证据只留在对话栏生命周期内，不持久化，不查询可能导致旧版 Chromium 崩溃的旧权限名。 */
export function checkHost({ previouslyReachedHost = false }: { previouslyReachedHost?: boolean } = {}): Promise<HostConnection> {
	return detect(false, previouslyReachedHost);
}

export function requestHostAccess(): Promise<HostConnection> {
	return detect(true);
}
