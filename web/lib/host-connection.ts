import { resolveWebBaseUrl } from "./seo";

/**
 * 课程学习页 ↔ 本机 Host 的连接检测（R26、R28；KTD4、KTD10、KTD15；ADR-0022）。
 *
 * 只产出 R26 的状态，不带文案：文案由对话栏（U10）用自己的 i18n 命名空间给出。
 * 两个入口，区别只在「未授权时发不发本机请求」：
 * - checkHost()：页面加载、自动重连时调用。本机访问未授权时只回报状态，不发请求。
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

/** KTD15：`/health` 报告的版本低于它，就进入「Host 需要更新」 */
export const MIN_HOST_VERSION = "0.1.0";

export type HostConnection =
	| { state: "unsupported"; reason: "browser" }
	| { state: "unsupported"; reason: "address"; canonicalUrl: string }
	| { state: "needsPermission" }
	| { state: "blocked" }
	| { state: "noHost" }
	| { state: "staleHost" }
	/** ompPresent / paired 由对话栏映射到「电脑上找不到 OMP」「未配对」，再决定是否打开 WebSocket */
	| { state: "detected"; ompPresent: boolean; paired: boolean };

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
			ompPresent: boolean;
			paired: boolean;
		};
		if (health.version.localeCompare(MIN_HOST_VERSION, "en", { numeric: true }) < 0) {
			return { state: "staleHost" };
		}
		return { state: "detected", ompPresent: health.ompPresent, paired: health.paired };
	} catch {
		return null;
	}
}

async function detect(fromUserGesture: boolean): Promise<HostConnection> {
	// Host 只认构建时写死的唯一来源（KTD4）；换个地址打开（127.0.0.1、预览域名）一律连不上
	const canonicalOrigin = new URL(resolveWebBaseUrl()).origin;
	if (location.origin !== canonicalOrigin) {
		return {
			state: "unsupported",
			reason: "address",
			canonicalUrl: `${canonicalOrigin}${location.pathname}${location.search}${location.hash}`,
		};
	}

	// ADR-0022：首期只支持 macOS 上的 Chrome——安装命令只有 macOS 版。不能只看 permissions API：
	// Safari 也有它，查这个权限名同样抛 TypeError，会被当成「需要授权」；而 Safari 把 https 页面
	// 到 127.0.0.1 的请求当混用内容拦掉。userAgentData 只有 Chromium 有，一个条件同时排除两类。
	if (navigator.userAgentData?.platform !== "macOS" || !navigator.permissions) {
		return { state: "unsupported", reason: "browser" };
	}

	if (!fromUserGesture) {
		const permission = await loopbackPermission();
		if (permission === "denied") return { state: "blocked" };
		if (permission !== "granted") return { state: "needsPermission" };
	}

	const probed = await probe();
	if (probed) return probed;

	// 被拒的失败是静默的（WebSocket 只见 close code 1006），只能回头问授权状态：
	// 拒了是被浏览器阻止；关掉提示仍需授权；其余（含已授权）是本机没有在跑的 Host
	const permission = await loopbackPermission();
	if (permission === "denied") return { state: "blocked" };
	if (permission === "prompt") return { state: "needsPermission" };
	return { state: "noHost" };
}

export function checkHost(): Promise<HostConnection> {
	return detect(false);
}

export function requestHostAccess(): Promise<HostConnection> {
	return detect(true);
}
