// platform-dialog.test.ts — 三系统的确认弹窗（KTD3）：命令形状、默认即拒绝、文字只经 argv、
// 运行器对 zenity 退出码与 cscript 临时脚本的处理（临时脚本内容固定、用完即删）。
import { afterEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DIALOG_SCRIPT, WINDOWS_SCRIPT, dialogCommand, runPlatformDialog } from "../src/platform-dialog";

const account = { displayName: "甲", maskedIdentifier: "a***@example.com" };
const cleanups: (() => void)[] = [];
afterEach(() => {
  for (const f of cleanups.splice(0).reverse()) f();
});
const temp = () => {
  const dir = mkdtempSync(join(tmpdir(), "cgc-dialog-test-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
};
/** 在 PATH 最前放一个垫片，并恢复原有 PATH */
function shim(name: string, body: string) {
  const dir = temp();
  const file = join(dir, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`);
  chmodSync(file, 0o755);
  const old = process.env.PATH;
  process.env.PATH = `${dir}:${old}`;
  cleanups.push(() => (process.env.PATH = old));
}

test("macOS：osascript 固定脚本；默认按钮=取消按钮=拒绝，限时后按拒绝处理", () => {
  const argv = dialogCommand("darwin", account, "zh-CN");
  expect(argv.slice(0, 4)).toEqual(["/usr/bin/osascript", "-e", DIALOG_SCRIPT, "--"]);
  expect(DIALOG_SCRIPT).toContain("default button 1 cancel button 1");
  expect(DIALOG_SCRIPT).toContain("giving up after");
  expect(argv[6]).toBe("拒绝");
  expect(argv.at(-1)).toBe("60");
});

test("Windows：cscript 跑系统自带 Popup；默认第二个按钮=否，文字只经参数", () => {
  const argv = dialogCommand("win32", account, "zh-CN");
  expect(argv[0]).toBe("cscript");
  expect(argv[3]).toBe("-"); // 脚本文件占位符，运行时才写入
  expect(WINDOWS_SCRIPT).toContain("Popup");
  expect(WINDOWS_SCRIPT).toContain("4+256+48"); // 是/否 + 默认「否」 + 警告
  expect(argv.join("\n")).toContain("甲（a***@example.com）");
  expect(argv.at(-1)).toBe("60");
});

test("Ubuntu：zenity 问题框；默认焦点在取消上，超时 60 秒", () => {
  const argv = dialogCommand("linux", account, "zh-CN");
  expect(argv[0]).toBe("zenity");
  expect(argv).toContain("--default-cancel");
  expect(argv).toContain("--timeout=60");
  expect(argv).toContain("--ok-label=允许");
  expect(argv).toContain("--cancel-label=拒绝");
});

test("en 出英文，白名单外的 locale 退回 zh-CN（三平台同口径）", () => {
  for (const platform of ["darwin", "win32", "linux"] as const) {
    expect(dialogCommand(platform, account, "en").join("\n")).toContain("CGC account");
    expect(dialogCommand(platform, account, "fr").join("\n")).toContain("CGC 账号");
  }
});

test("三个平台：显示名里的引号/反斜杠只出现在一个 argv 元素里，不进固定脚本", () => {
  const payload = `" & (do shell script "touch /tmp/pwned") & "\\ \\"`;
  for (const platform of ["darwin", "win32", "linux"] as const) {
    const argv = dialogCommand(platform, { displayName: payload, maskedIdentifier: null }, "zh-CN");
    expect(argv.filter((a) => a.includes(payload))).toHaveLength(1);
  }
  expect(DIALOG_SCRIPT).not.toContain("do shell script");
  expect(WINDOWS_SCRIPT).not.toContain("do shell script");
});

test("zenity 运行器：0=允许、5=超时、1=拒绝；临时脚本用完即删、内容固定", async () => {
  const record = join(temp(), "argv.txt");
  shim("zenity", `printf '%s\\n' "$@" >"${record}"; exit "\${ZENITY_EXIT:-0}"`);
  const argv = dialogCommand("linux", account, "zh-CN");
  expect(await runPlatformDialog(argv, new AbortController().signal)).toBe("allow");
  expect(readFileSync(record, "utf8")).toContain("--default-cancel");
  process.env.ZENITY_EXIT = "5";
  expect(await runPlatformDialog(argv, new AbortController().signal)).toBe("timeout");
  process.env.ZENITY_EXIT = "1";
  expect(await runPlatformDialog(argv, new AbortController().signal)).toBe("deny");
  delete process.env.ZENITY_EXIT;
});

test("cscript 运行器：固定脚本写入临时文件并作为脚本运行，参数即文字，返回后临时文件删除", async () => {
  const dir = temp();
  const record = join(dir, "args.txt");
  const scriptCopy = join(dir, "script.js");
  shim("cscript", `args=""; for a in "$@"; do args="$args|$a"; done; printf '%s' "$args" >"${record}"; cp "$3" "${scriptCopy}"; printf 'allow'`);
  const argv = dialogCommand("win32", account, "zh-CN");
  expect(await runPlatformDialog(argv, new AbortController().signal)).toBe("allow");

  const args = readFileSync(record, "utf8").split("|");
  // cscript //NoLogo //E:JScript <临时脚本> <正文> <标题> <秒>
  expect(args[1]).toBe("//NoLogo");
  expect(args[2]).toBe("//E:JScript");
  expect(readFileSync(scriptCopy, "utf8")).toBe(WINDOWS_SCRIPT);
  expect(args[4]).toContain("a***@example.com");
  expect(args[6]).toBe("60");
  expect(existsSync(args[3])).toBe(false); // 用完即删
});
