import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { assertHostVersionContract, compareHostVersions } from "./host-version";
import {
	HOST_HTTP_ORIGIN,
	HOST_PORT,
	MIN_HOST_VERSION,
	checkHost,
	courseDir,
	requestHostAccess,
} from "./host-connection";

/**
 * U8 本机连接检测（R26 状态映射，AE12 版本下限）。
 *
 * 浏览器全局（location / navigator / fetch）整体用 vi.stubGlobal 替换：
 * `navigator.userAgentData` 的有无与 platform、`navigator.permissions` 的有无本身就是判定分支。
 * 端口契约同 `lib/error-codes.contract.test.ts`，跨目录直接读 `cgc-host/protocol.json`。
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const PROTOCOL_PATH = resolve(HERE, "../../cgc-host/protocol.json");

const CANONICAL = "https://codingirlsclub.com";

function stubBrowser({
	origin = CANONICAL,
	platform = "macOS" as string | null,
	userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36",
	permissions = true,
	permission = "granted" as PermissionState | "TypeError",
	health = { version: MIN_HOST_VERSION, agents: [{ kind: "omp", present: true }], paired: true } as
		| object
		| "unreachable",
} = {}) {
	vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", CANONICAL);
	vi.stubGlobal("location", new URL(`${origin}/courses/c1/learn?unit=u1`));

	const permissionQuery = vi.fn(async (_query: { name: string }) => {
		if (_query.name !== "loopback-network") throw new Error("unexpected permission name");
		if (permission === "TypeError") throw new TypeError("not a valid enum value");
		return { state: permission };
	});
	vi.stubGlobal("navigator", {
		userAgent,
		...(platform === null ? {} : { userAgentData: { platform } }),
		...(permissions ? { permissions: { query: permissionQuery } } : {}),
	});

	const fetchMock = vi.fn(async () => {
		if (health === "unreachable") throw new TypeError("Failed to fetch");
		return new Response(JSON.stringify(health));
	});
	vi.stubGlobal("fetch", fetchMock);

	return { permissionQuery, fetchMock };
}

afterEach(() => {
	vi.unstubAllGlobals();
	vi.unstubAllEnvs();
});

it("web 侧端口常量与 cgc-host/protocol.json 一致（改端口即改协议）", () => {
	const { port } = JSON.parse(readFileSync(PROTOCOL_PATH, "utf8")) as {
		port: number;
	};

	expect(HOST_PORT).toBe(port);
});

it("真实最低版本契约：Web 的最低版本不高于待发布 Host 包", () => {
	const packaged = JSON.parse(readFileSync(resolve(HERE, "../../cgc-host/package.json"), "utf8"));
	expect(() => assertHostVersionContract(MIN_HOST_VERSION, packaged.version)).not.toThrow();
	expect(compareHostVersions(MIN_HOST_VERSION, packaged.version)).toBeLessThanOrEqual(0);
		expect(() => assertHostVersionContract("9.9.9", packaged.version)).toThrow("MIN_HOST_VERSION exceeds");
});

it("R15 路径契约：对话栏显示的作业目录与 Host 的 workDir 同一棵树（跨包无共享，读源码钉住）", () => {
	const source = readFileSync(resolve(HERE, "../../cgc-host/src/state.ts"), "utf8");
	const dirs = {
		workspace: /export const WORKSPACE_DIR = "([^"]+)";/.exec(source)?.[1],
		courses: /export const COURSES_DIR = "([^"]+)";/.exec(source)?.[1],
	};
	const body = /return join\(home, WORKSPACE_DIR, COURSES_DIR, userId, courseId\);/.test(source);
	expect(dirs).toEqual({ workspace: "cgc2046_workspace", courses: "courses" });
	expect(body).toBe(true);
	expect(courseDir("u", "c")).toBe(`~/${dirs.workspace}/${dirs.courses}/u/c`);
});

describe("checkHost（页面加载即可调用；未授权时不发本机请求）", () => {
	it("非规范访问地址 → 不受支持（address），给出同一页面的规范地址", async () => {
		const { permissionQuery, fetchMock } = stubBrowser({
			origin: "http://127.0.0.1:3000",
		});

		expect(await checkHost()).toEqual({
			state: "unsupported",
			reason: "address",
			canonicalUrl: `${CANONICAL}/courses/c1/learn?unit=u1`,
		});
		expect(permissionQuery).not.toHaveBeenCalled();
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it.each(["macOS", "Windows", "Linux"])("%s 上的 Chrome 进入本机访问权限判定", async (platform) => {
		const { permissionQuery, fetchMock } = stubBrowser({ platform, permission: "prompt" });
		expect(await checkHost()).toEqual({ state: "needsPermission" });
		expect(permissionQuery).toHaveBeenCalledOnce();
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it.each([
		["无 userAgentData 且 UA 不含 Firefox（Safari 等；有 permissions API 也一样）", null],
		["ChromeOS 或移动 Chromium", "Android"],
	])("不支持的浏览器：%s → 不受支持（browser），不查权限也不碰本机", async (_, platform) => {
		const { permissionQuery, fetchMock } = stubBrowser({ platform });

		expect(await checkHost()).toEqual({ state: "unsupported", reason: "browser" });
		expect(permissionQuery).not.toHaveBeenCalled();
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("macOS 上的 Chromium → 进入本机访问权限判定", async () => {
		const { permissionQuery } = stubBrowser({ platform: "macOS", permission: "prompt" });

		expect(await checkHost()).toEqual({ state: "needsPermission" });
		expect(permissionQuery).toHaveBeenCalledWith({ name: "loopback-network" });
	});

	it("navigator.permissions 不存在 → 不受支持（browser）", async () => {
		const { fetchMock } = stubBrowser({ permissions: false });

		expect(await checkHost()).toEqual({ state: "unsupported", reason: "browser" });
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("权限查询抛 TypeError → 需要授权，且不发本机请求", async () => {
		const { fetchMock } = stubBrowser({ permission: "TypeError" });

		expect(await checkHost()).toEqual({ state: "needsPermission" });
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("权限为 prompt → 需要授权，且不发本机请求（第一次请求留给用户手势）", async () => {
		const { fetchMock } = stubBrowser({ permission: "prompt" });

		expect(await checkHost()).toEqual({ state: "needsPermission" });
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("权限为 denied → 被浏览器阻止", async () => {
		const { fetchMock } = stubBrowser({ permission: "denied" });

		expect(await checkHost()).toEqual({ state: "blocked" });
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("已授权但探测失败 → 未检测到 Host；探测带 loopback 地址空间声明", async () => {
		const { fetchMock } = stubBrowser({ health: "unreachable" });

		expect(await checkHost()).toEqual({ state: "noHost" });
		expect(fetchMock).toHaveBeenCalledWith(`${HOST_HTTP_ORIGIN}/health`, {
			targetAddressSpace: "loopback",
		});
	});

	it("Covers AE12：Host 版本低于下限 → Host 需要更新", async () => {
		stubBrowser({ health: { version: "0.0.9", agents: [{ kind: "omp", present: true }], paired: true } });

		expect(await checkHost()).toEqual({ state: "staleHost" });
	});

	it.each(["0.1", "v0.1.10", "01.1.0", "0.1.0-beta", "0.1.0+build", "0.1.9007199254740992"])("非法 Host 版本 %s 不能被视为可连接", async (version) => {
		stubBrowser({ health: { version, agents: [{ kind: "omp", present: true }], paired: true } });
		expect(await checkHost()).toEqual({ state: "noHost" });
	});

	it("版本满足下限 → 检测到 Host，并带回各 agent 与配对情况", async () => {
		stubBrowser({
			health: { version: MIN_HOST_VERSION, agents: [{ kind: "omp", present: false }], paired: true },
		});

		expect(await checkHost()).toEqual({
			state: "detected",
			agents: [{ kind: "omp", present: false }],
			paired: true,
		});
	});

	it("只装了 Codex 的机器也算「有可用的 agent」（ompPresent 为 false 不代表不可用）", async () => {
		stubBrowser({
			health: { version: MIN_HOST_VERSION, ompPresent: false, paired: true, agents: [{ kind: "omp", present: false }, { kind: "codex", present: true }] },
		});

		expect(await checkHost()).toEqual({
			state: "detected",
			agents: [{ kind: "omp", present: false }, { kind: "codex", present: true }],
			paired: true,
		});
	});

	it("旧 Host 只报 ompPresent（没有 agents 字段）时按 OMP 回落：结构化数据缺失不等于不可连", async () => {
		stubBrowser({ health: { version: MIN_HOST_VERSION, ompPresent: true, paired: true } });

		expect(await checkHost()).toEqual({
			state: "detected",
			agents: [{ kind: "omp", present: true }],
			paired: true,
		});
	});
});

describe("桌面 Firefox（无 UA Client Hints、无浏览器级回环权限模型）", () => {
	const FF = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:157.0) Gecko/20100101 Firefox/157.0";

	it("不查权限、直接探测；Host 可达 → detected", async () => {
		const { permissionQuery, fetchMock } = stubBrowser({ platform: null, userAgent: FF });
		expect(await checkHost()).toMatchObject({ state: "detected" });
		expect(permissionQuery).not.toHaveBeenCalled();
		expect(fetchMock).toHaveBeenCalledOnce();
	});

	it("Host 未运行 → noHost（不是 needsPermission，不出现无意义的「允许访问本机」引导）", async () => {
		const { permissionQuery, fetchMock } = stubBrowser({ platform: null, userAgent: FF, health: "unreachable" });
		expect(await checkHost()).toEqual({ state: "noHost" });
		expect(permissionQuery).not.toHaveBeenCalled();
		expect(fetchMock).toHaveBeenCalledOnce();
	});

	it("requestHostAccess 同路径：直接探测，无权限查询", async () => {
		const { permissionQuery } = stubBrowser({ platform: null, userAgent: FF });
		expect(await requestHostAccess()).toMatchObject({ state: "detected" });
		expect(permissionQuery).not.toHaveBeenCalled();
	});

	it("Firefox Android / Mobile → 不受支持（browser）", async () => {
		const { fetchMock } = stubBrowser({ platform: null, userAgent: "Mozilla/5.0 (Android 14; Mobile; rv:157.0) Gecko/157.0 Firefox/157.0" });
		expect(await checkHost()).toEqual({ state: "unsupported", reason: "browser" });
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("Safari（有 permissions、无 userAgentData、UA 无 Firefox 令牌）→ 不受支持", async () => {
		const { fetchMock } = stubBrowser({ platform: null, userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15" });
		expect(await checkHost()).toEqual({ state: "unsupported", reason: "browser" });
		expect(fetchMock).not.toHaveBeenCalled();
	});
});

describe("requestHostAccess（从点击处理器调用：由用户手势发出第一次本机请求）", () => {
	it("权限仍为 prompt 也直接探测，由这次请求触发浏览器的授权提示", async () => {
		const { fetchMock } = stubBrowser({ permission: "prompt" });

		expect(await requestHostAccess()).toEqual({
			state: "detected",
			agents: [{ kind: "omp", present: true }],
			paired: true,
		});
		expect(fetchMock).toHaveBeenCalledOnce();
	});

	it("学员在提示里拒绝（探测失败后权限为 denied）→ 被浏览器阻止", async () => {
		stubBrowser({ permission: "denied", health: "unreachable" });

		expect(await requestHostAccess()).toEqual({ state: "blocked" });
	});

	it.each(["prompt", "TypeError"] as const)("点击探测失败且权限为 %s：保留未知状态与失败证据，后续自动检查不发请求", async (permission) => {
		const { fetchMock } = stubBrowser({ permission, health: "unreachable" });
		expect(await requestHostAccess()).toEqual({ state: "needsPermission", probeFailed: true });
		expect(await checkHost()).toEqual({ state: "needsPermission" });
		expect(fetchMock).toHaveBeenCalledOnce();
	});
});


describe("成功访问过 Host 后自动重连（Chrome 142–144 及权限始终 prompt 的浏览器）", () => {
  it.each(["TypeError", "prompt"] as const)("权限 %s：首次仍等手势；有成功探测证据后可自动重连", async (permission) => {
    const { fetchMock, permissionQuery } = stubBrowser({ permission });
    expect(await checkHost()).toEqual({ state: "needsPermission" });
    expect(fetchMock).not.toHaveBeenCalled();
    expect(await requestHostAccess()).toMatchObject({ state: "detected" });
    expect(await checkHost({ previouslyReachedHost: true })).toMatchObject({ state: "detected" });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(permissionQuery.mock.calls.every(([q]) => q.name === "loopback-network")).toBe(true);
  });
  it("已有成功证据但权限被明确撤回：不请求本机", async () => {
    const { fetchMock } = stubBrowser({ permission: "denied" });
    expect(await checkHost({ previouslyReachedHost: true })).toEqual({ state: "blocked" });
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it("已有成功证据但 Host 暂停、权限仍为 prompt：回 noHost，后续轮询继续尝试", async () => {
    const { fetchMock } = stubBrowser({ permission: "prompt", health: "unreachable" });
    expect(await checkHost({ previouslyReachedHost: true })).toEqual({ state: "noHost" });
    expect(fetchMock).toHaveBeenCalledOnce();
  });
});
