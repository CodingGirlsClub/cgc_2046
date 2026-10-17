// install.test.ts — 页面一键安装（期 2）：在临时目录里装、失败不留残留、单飞、版本校验、卸载清理
import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pickCodexAcp } from "../src/agents/codex";
import {
  CODEX_ACP_VERSION,
  InstallError,
  agentsDir,
  codexAgentDir,
  codexPackageDir,
  installCodexAcp,
  installedVersion,
  managedCodex,
  managedCodexEntry,
} from "../src/agents/install";
import { uninstall } from "../src/uninstall";
import { cleanup, tempHome } from "./helpers";

afterEach(cleanup);

/**
 * 假安装：造出 bun install 完成后的形状（版本可改，用来测 version_mismatch）。
 * 入口从 manifest 的 bin 解析，所以这里必须写下 bin——真实包也一样（dist/index.js）。
 */
function fakeInstaller(version = CODEX_ACP_VERSION) {
  return async (cwd: string) => {
    const pkg = join(cwd, "node_modules", "@agentclientprotocol", "codex-acp");
    mkdirSync(join(pkg, "dist"), { recursive: true });
    writeFileSync(join(pkg, "package.json"), JSON.stringify({ name: "@agentclientprotocol/codex-acp", version, bin: { "codex-acp": "dist/index.js" } }));
    writeFileSync(join(pkg, "dist", "index.js"), "#!/usr/bin/env node\n");
    return 0;
  };
}

/** 安装目录里不该留下的中间产物（.tmp-* 是没装完的，.old-* 是换下来的） */
const leftovers = (home: string) => readdirSync(agentsDir(home)).filter((name) => name.startsWith(".tmp-") || name.startsWith(".old-"));
/** 托管入口（版本门通过时） */
const managedCodexAcpEntry = (home: string) => managedCodexEntry(home);

describe("installCodexAcp", () => {
  test("装到 ~/.cgc2046/agents/codex-acp：版本可读、不留临时目录、探测立刻看得到", async () => {
    const home = tempHome();
    expect(await installCodexAcp({ home, run: fakeInstaller() })).toEqual({ version: CODEX_ACP_VERSION });
    expect(installedVersion(home)).toBe(CODEX_ACP_VERSION);
    expect(managedCodexAcpEntry(home)).not.toBeNull();
    expect(leftovers(home)).toEqual([]);
    // 托管安装优先于 PATH 上的同名命令（学员自己也可能装过一份；这里 PATH 里没有）
    expect(pickCodexAcp(home, "")).toBe(managedCodex(home));
  });

  test("退出码非 0：install_failed，不落目录、不留临时目录", async () => {
    const home = tempHome();
    await expect(installCodexAcp({ home, run: async () => 1 })).rejects.toBeInstanceOf(InstallError);
    await expect(installCodexAcp({ home, run: async () => 1 })).rejects.toMatchObject({ code: "install_failed" });
    expect(existsSync(codexAgentDir(home))).toBe(false);
    expect(leftovers(home)).toEqual([]);
  });

  test("装上的版本与钉住的不一致：version_mismatch，同样不留残留", async () => {
    const home = tempHome();
    await expect(installCodexAcp({ home, run: fakeInstaller("0.0.1") })).rejects.toMatchObject({ code: "version_mismatch" });
    expect(existsSync(codexAgentDir(home))).toBe(false);
    expect(leftovers(home)).toEqual([]);
  });

  test("重复安装：原子替换，换下来的旧目录不残留", async () => {
    const home = tempHome();
    await installCodexAcp({ home, run: fakeInstaller() });
    await installCodexAcp({ home, run: fakeInstaller() });
    expect(installedVersion(home)).toBe(CODEX_ACP_VERSION);
    expect(leftovers(home)).toEqual([]);
  });

  test("上次被中断留下的 .tmp-* / .old-* 会被清掉", async () => {
    const home = tempHome();
    mkdirSync(join(agentsDir(home), ".tmp-stale"), { recursive: true });
    mkdirSync(join(agentsDir(home), ".old-stale"), { recursive: true });
    await installCodexAcp({ home, run: fakeInstaller() });
    expect(leftovers(home)).toEqual([]);
  });

  test("单飞：正在装时再点一次拿同一个结果，安装只跑一遍", async () => {
    const home = tempHome();
    let calls = 0;
    const run = async (cwd: string) => {
      calls += 1;
      await Bun.sleep(20);
      return fakeInstaller()(cwd);
    };
    const [a, b] = await Promise.all([installCodexAcp({ home, run }), installCodexAcp({ home, run })]);
    expect(calls).toBe(1);
    expect(a).toEqual(b);
  });

  test("超时：timeout，临时目录照样清掉", async () => {
    const home = tempHome();
    const run = () => new Promise<number>(() => {}); // 永不返回
    await expect(installCodexAcp({ home, run, timeoutMs: 30 })).rejects.toMatchObject({ code: "timeout" });
    expect(leftovers(home)).toEqual([]);
  });
});

test("卸载删掉 Host 装的 agent，学员自己的 ~/.codex 原样保留", async () => {
  const home = tempHome();
  await installCodexAcp({ home, run: fakeInstaller() });
  mkdirSync(join(home, ".codex"), { recursive: true });
  writeFileSync(join(home, ".codex", "config.toml"), 'model = "gpt"\n');
  await uninstall(home, "http://127.0.0.1:9"); // 没有配对记录：不会发任何网络请求
  expect(existsSync(agentsDir(home))).toBe(false);
  expect(readFileSync(join(home, ".codex", "config.toml"), "utf8")).toContain('model = "gpt"');
});

describe("Windows 布局与版本门", () => {
	test("Windows：Bun 只生成 .exe/.bunx，没有无扩展名文件——入口仍从 manifest 解析得到", async () => {
		const home = tempHome();
		await installCodexAcp({ home, run: fakeInstaller() });
		// 模拟 Windows 上 bun 的 shim：删掉无扩展名入口，只留 .exe/.bunx（新实现本来就不依赖它们）
		const binDir = join(codexPackageDir(home), "..", "..", ".bin");
		rmSync(binDir, { recursive: true, force: true });
		mkdirSync(binDir, { recursive: true });
		writeFileSync(join(binDir, "codex-acp.exe"), "");
		writeFileSync(join(binDir, "codex-acp.bunx"), "");

		expect(managedCodexEntry(home)).toBe(join(codexPackageDir(home), "dist", "index.js"));
		expect(managedCodex(home)).toBe(join(codexPackageDir(home), "dist", "index.js"));
	});

	test("版本门：托管副本版本与钉住的不一致时不再采用（Host 升级后旧副本自动让位）", async () => {
		const home = tempHome();
		await installCodexAcp({ home, run: fakeInstaller() });
		// 人为把已装版本改旧：模拟 Host 升级 CODEX_ACP_VERSION 之后、学员还没重装
		const manifest = join(codexPackageDir(home), "package.json");
		writeFileSync(manifest, JSON.stringify({ name: "@agentclientprotocol/codex-acp", version: "0.0.1", bin: { "codex-acp": "dist/index.js" } }));
		expect(managedCodexEntry(home)).not.toBeNull(); // 文件还在
		expect(managedCodex(home)).toBeNull(); // 但版本门不让它进
		expect(pickCodexAcp(home, "")).toBeNull(); // PATH 上也没有 → 页面重新给安装入口
	});

	test("幂等短路：已经装着钉住的版本时不再跑安装", async () => {
		const home = tempHome();
		await installCodexAcp({ home, run: fakeInstaller() });
		let calls = 0;
		const second = await installCodexAcp({ home, run: async () => { calls += 1; return 0; } });
		expect(second.version).toBe(CODEX_ACP_VERSION);
		expect(calls).toBe(0);
	});

	test("PATH 上也有 codex-acp 时，版本匹配的托管安装优先（BYO 回退只在托管不可用时生效）", async () => {
		const home = tempHome();
		await installCodexAcp({ home, run: fakeInstaller() });
		// 造一个真实可执行的 PATH 项：Bun.which 会找到它，但托管安装应该仍然胜出
		const pathDir = join(home, "fake-path");
		mkdirSync(pathDir, { recursive: true });
		const pathBin = join(pathDir, "codex-acp");
		writeFileSync(pathBin, "#!/bin/sh\nexit 0\n");
		chmodSync(pathBin, 0o755);
		expect(Bun.which("codex-acp", { PATH: pathDir })).toBe(pathBin); // 前提成立：PATH 里确实有

		expect(pickCodexAcp(home, pathDir)).toBe(managedCodex(home));
	});
});
