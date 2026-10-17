// install.test.ts — 页面一键安装（期 2）：在临时目录里装、失败不留残留、单飞、版本校验、卸载清理
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pickCodexAcp } from "../src/agents/codex";
import {
  CODEX_ACP_VERSION,
  InstallError,
  agentsDir,
  codexAgentDir,
  installCodexAcp,
  installedVersion,
  managedCodexAcp,
} from "../src/agents/install";
import { uninstall } from "../src/uninstall";
import { cleanup, tempHome } from "./helpers";

afterEach(cleanup);

/** 假安装：造出 bun install 完成后的形状（版本可改，用来测 version_mismatch） */
function fakeInstaller(version = CODEX_ACP_VERSION) {
  return async (cwd: string) => {
    const pkg = join(cwd, "node_modules", "@agentclientprotocol", "codex-acp");
    mkdirSync(join(pkg, "dist"), { recursive: true });
    writeFileSync(join(pkg, "package.json"), JSON.stringify({ name: "@agentclientprotocol/codex-acp", version }));
    mkdirSync(join(cwd, "node_modules", ".bin"), { recursive: true });
    writeFileSync(join(cwd, "node_modules", ".bin", "codex-acp"), "#!/usr/bin/env node\n");
    return 0;
  };
}

/** 安装目录里不该留下的中间产物（.tmp-* 是没装完的，.old-* 是换下来的） */
const leftovers = (home: string) => readdirSync(agentsDir(home)).filter((name) => name.startsWith(".tmp-") || name.startsWith(".old-"));

describe("installCodexAcp", () => {
  test("装到 ~/.cgc2046/agents/codex-acp：版本可读、不留临时目录、探测立刻看得到", async () => {
    const home = tempHome();
    expect(await installCodexAcp({ home, run: fakeInstaller() })).toEqual({ version: CODEX_ACP_VERSION });
    expect(installedVersion(home)).toBe(CODEX_ACP_VERSION);
    expect(existsSync(managedCodexAcp(home))).toBe(true);
    expect(leftovers(home)).toEqual([]);
    // 托管安装优先于 PATH 上的同名命令（学员自己也可能装过一份）
    expect(pickCodexAcp(home, "")).toBe(managedCodexAcp(home));
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
