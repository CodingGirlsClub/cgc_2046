// sources.test.ts — Codex「来源」只读探测：托管安装 / PATH 适配器 / ChatGPT App 内置 engine / PATH codex CLI。
// 约束：按优先级去重、不启动任何进程、不改变安装与启动行为（只上报）。
import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { CODEX_ACP_VERSION, codexAgentDir } from "../src/agents/install";
import { agentLocator, createRegistry, type Locator } from "../src/agents/registry";
import { detectCodexSources } from "../src/agents/sources";
import { SITE_ORIGIN } from "../src/config";
import { cleanup, startHost, tempHome } from "./helpers";

afterEach(cleanup);

/** 造一个可执行的假入口（Bun.which / existsSync 都认） */
function fakeExecutable(dir: string, name: string): string {
  mkdirSync(dir, { recursive: true });
  const path = join(dir, name);
  writeFileSync(path, "#!/bin/sh\nexit 0\n");
  chmodSync(path, 0o755);
  return path;
}

/** 托管安装的落盘形状（入口从 manifest 的 bin 解析） */
function fakeManagedInstall(home: string, version = CODEX_ACP_VERSION): string {
  const pkg = join(codexAgentDir(home), "node_modules", "@agentclientprotocol", "codex-acp");
  mkdirSync(join(pkg, "dist"), { recursive: true });
  writeFileSync(join(pkg, "package.json"), JSON.stringify({ name: "@agentclientprotocol/codex-acp", version, bin: { "codex-acp": "dist/index.js" } }));
  writeFileSync(join(pkg, "dist", "index.js"), "#!/usr/bin/env node\n");
  return join(pkg, "dist", "index.js");
}

/** ChatGPT.app 内置 codex-cli 的落盘形状（macOS 实测结构） */
function fakeChatgptApp(root: string, version = "0.163.0-alpha.10.2"): string {
  const cliDir = join(root, "Contents", "Resources", "codex-cli");
  const entry = fakeExecutable(join(cliDir, "bin"), "codex");
  writeFileSync(join(cliDir, "codex-package.json"), JSON.stringify({ layoutVersion: 1, version }));
  return entry;
}

describe("detectCodexSources", () => {
	test("托管安装优先，并带上已装版本", () => {
		const home = tempHome();
		const expectedPath = fakeManagedInstall(home);

		const hits = detectCodexSources(home, "", { platform: "linux" });

		expect(hits).toHaveLength(1);
		expect(hits[0]).toMatchObject({ source: "managed", path: expectedPath, version: CODEX_ACP_VERSION });
	});

	test("PATH 上的 codex-acp 会被探测到（版本未知记 null）", () => {
		const home = tempHome();
		const pathDir = join(home, "fake-path");
		fakeExecutable(pathDir, "codex-acp");

		const hits = detectCodexSources(home, pathDir, { platform: "linux" });

		expect(hits.map((hit) => hit.source)).toEqual(["codex-acp"]);
		expect(hits[0]?.version).toBeNull();
	});

	test("ChatGPT App 内置 engine：从 codex-package.json 取版本", () => {
		const home = tempHome();
		const appEntry = fakeChatgptApp(join(home, "FakeChatGPT.app"));

		const hits = detectCodexSources(home, "", { platform: "darwin", appCandidates: [appEntry] });

		expect(hits).toHaveLength(1);
		expect(hits[0]).toMatchObject({ source: "chatgpt-app", path: appEntry, version: "0.163.0-alpha.10.2" });
	});

	test("非 macOS 不探测 App 内置路径（Windows/Linux 待逐平台验证，见 #1155）", () => {
		const home = tempHome();
		const appEntry = fakeChatgptApp(join(home, "FakeChatGPT.app"));

		expect(detectCodexSources(home, "", { platform: "linux", appCandidates: [appEntry] })).toEqual([]);
	});

	test("同一入口同时出现在 App 与 PATH 时按真实路径去重，只保留 App 那条", () => {
		const home = tempHome();
		const pathDir = join(home, "fake-path");
		mkdirSync(pathDir, { recursive: true });
		const appEntry = fakeChatgptApp(join(home, "FakeChatGPT.app"));
		symlinkSync(appEntry, join(pathDir, "codex"));
		// 前提：Bun.which 确实能在 PATH 里找到这条 codex
		expect(Bun.which("codex", { PATH: pathDir })).toBe(join(pathDir, "codex"));

		const hits = detectCodexSources(home, pathDir, { platform: "darwin", appCandidates: [appEntry] });

		expect(hits.map((hit) => hit.source)).toEqual(["chatgpt-app"]);
	});

	test("都没有时返回空数组（不误报）", () => {
		const home = tempHome();
		expect(detectCodexSources(home, join(home, "empty-path"), { platform: "darwin", appCandidates: [] })).toEqual([]);
	});
});

describe("status 上报 sources（只增量，不改 present）", () => {
	test("registry.status 透传定位器给出的 sources", async () => {
		const locator: Locator = {
			locate: async () => ({ path: "/usr/local/bin/codex-acp", env: {}, envError: null, sources: [{ source: "chatgpt-app", version: "0.163.0" }] }),
			present: () => true,
			envError: () => null,
			sources: () => [{ source: "chatgpt-app", version: "0.163.0" }],
		};
		const registry = createRegistry([
			{ kind: "codex", mcpServerName: "cgc-2046-learning", locator, start: async () => { throw new Error("unused"); } },
		]);

		expect(registry.status()).toEqual([{ kind: "codex", present: true, sources: [{ source: "chatgpt-app", version: "0.163.0" }] }]);
	});

	test("agentLocator 缓存最近一次 sources", async () => {
		const locator = agentLocator(async () => ({ path: "/x/codex-acp", env: {}, envError: null, sources: [{ source: "codex-cli", version: null }] }));
		expect(locator.sources?.()).toBeNull(); // 还没定位
		await locator.locate();
		expect(locator.sources?.()).toEqual([{ source: "codex-cli", version: null }]);
	});

	test("/health 原样带回带 sources 的 agent 条目（旧页面忽略即可）", async () => {
		const host = startHost({ agents: () => [{ kind: "codex", present: true, sources: [{ source: "chatgpt-app", version: "0.163.0" }] }] });

		const res = await fetch(`http://127.0.0.1:${host.port}/health`, { headers: { Origin: SITE_ORIGIN } });

		expect((await res.json()).agents).toEqual([{ kind: "codex", present: true, sources: [{ source: "chatgpt-app", version: "0.163.0" }] }]);
	});
});
