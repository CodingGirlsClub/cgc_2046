// platform-dialog.ts — 本机确认弹窗（KTD3）：按当前系统挑原装弹窗，文字只经 argv 传入、从不拼进脚本源码。
// macOS 用 osascript（DIALOG_SCRIPT），Windows 用系统自带脚本宿主 cscript + WScript.Shell.Popup（脚本文件内容固定，
// 运行时写到临时文件，账号等文字仍只经 argv 传给脚本），Ubuntu 桌面用 zenity。
// 三个入口同一契约：默认按钮 / 回车 / 关闭窗口 / 超时都不算「允许」，只有明确点允许才返回 "allow"。
import { randomUUID } from "node:crypto";
import { rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { DialogRunner } from "./pairing";

/**
 * macOS 弹窗脚本：文字全部经 argv 传入（osascript 的 `--` 之后），从不拼进脚本源码——
 * 显示名里的引号、反斜杠或 AppleScript 语句只会被原样显示。
 * 第一个按钮「拒绝」既是默认按钮也是取消按钮（回车、Esc 都是拒绝；取消让 osascript 以 -128 退出，stdout 为空）；
 * 限时不答即 timeout，同样按拒绝处理。
 */
export const DIALOG_SCRIPT = `on run argv
	set answer to display dialog (item 1 of argv) with title (item 2 of argv) buttons {item 3 of argv, item 4 of argv} default button 1 cancel button 1 with icon caution giving up after ((item 5 of argv) as integer)
	if gave up of answer then return "timeout"
	if button returned of answer is (item 4 of argv) then return "allow"
	return "deny"
end run`;

const DIALOG_SECONDS = 60;

type Account = { displayName?: string | null; maskedIdentifier?: string | null };

// locale 只选这里的文案；弹窗里唯一的变量是平台核实的账号
const COPY = {
  "zh-CN": {
    title: "CGC 学习连接",
    account: ({ displayName: n, maskedIdentifier: m }: Account) => (n && m ? `${n}（${m}）` : n || m || "（未设置名称）"),
    body: (account: string) =>
      `CGC 课程学习页请求连接这台电脑。\n\nCGC 账号：${account}\n\n允许后，这个浏览器里的课程页可以驱动你电脑上的 OMP，agent 以这个账号学习。如果不是你本人刚刚点了「连接」，请点「拒绝」。`,
    deny: "拒绝",
    allow: "允许",
  },
  en: {
    title: "CGC learning connection",
    account: ({ displayName: n, maskedIdentifier: m }: Account) => (n && m ? `${n} (${m})` : n || m || "(unnamed account)"),
    body: (account: string) =>
      `A CGC course page is asking to connect to this computer.\n\nCGC account: ${account}\n\nIf you allow it, the course page in this browser can drive OMP on this computer, and your agent will study as this account. If you did not just click "Connect", choose Deny.`,
    deny: "Deny",
    allow: "Allow",
  },
};

/**
 * 一次弹窗的命令行：按 platform 挑实现，文字只作为普通参数。
 * Windows 的第四项 `-` 是脚本文件占位符，runPlatformDialog 执行时换成临时写出的固定脚本。
 */
export function dialogCommand(platform: NodeJS.Platform, account: Account, locale: unknown): string[] {
  const copy = COPY[locale === "en" ? "en" : "zh-CN"];
  const body = copy.body(copy.account(account));
  if (platform === "win32") return ["cscript", "//NoLogo", "//E:JScript", "-", body, copy.title, String(DIALOG_SECONDS)];
  if (platform === "linux")
    return ["zenity", "--question", "--title", copy.title, "--text", body, `--ok-label=${copy.allow}`, `--cancel-label=${copy.deny}`, "--default-cancel", `--timeout=${DIALOG_SECONDS}`];
  // 其他平台（含 macOS）：osascript
  return ["/usr/bin/osascript", "-e", DIALOG_SCRIPT, "--", body, copy.title, copy.deny, copy.allow, String(DIALOG_SECONDS)];
}

/**
 * Windows 弹窗脚本（cscript 运行；内容固定，不进任何账号文字）。
 * 类型位 4+256+48 = 是/否按钮 + 默认第二个按钮（「否」）+ 警告图标；秒数到点自动消失。
 * Popup 返回 6「是」、7「否」、-1 超时；关闭窗口也会得到非 6 的码——都按拒绝处理。
 */
export const WINDOWS_SCRIPT =
  'var a=WScript.Arguments,answer=WScript.CreateObject("WScript.Shell").Popup(a(0),a(2),a(1),4+256+48);WScript.StdOut.Write(answer===6?"allow":answer===-1?"timeout":"deny");';

/** 真实的弹窗：按 argv 自述的实现分派。取消、被杀、出错都不会得到 "allow" */
export const runPlatformDialog: DialogRunner = async (argv, signal) => {
  let scriptFile: string | null = null;
  let command = argv;
  if (argv[0] === "cscript") {
    // 脚本内容固定（不含任何用户文字）；账号等文字走 WScript.Arguments(0..2)
    scriptFile = join(tmpdir(), `cgc-dialog-${randomUUID()}.js`);
    writeFileSync(scriptFile, WINDOWS_SCRIPT, { mode: 0o600 });
    command = [...argv.slice(0, 3), scriptFile, ...argv.slice(4)];
  }
  try {
    // 显式传当前环境：Bun.spawn 解析相对命令名（zenity/cscript）用的是进程启动时的 PATH 快照，
    // 显式 env 让它按现值的 PATH 解析，测试注入 PATH 垫片才能生效；生产两者相同。
    const proc = Bun.spawn(command, { stdout: "pipe", stderr: "pipe", env: { ...process.env }, signal, windowsHide: true });
    const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
    const code = await proc.exited;
    if (argv[0] === "zenity") {
      if (code === 0) return "allow";
      if (code === 5) return "timeout"; // 超时自动关闭
      if (code !== 1 && !signal.aborted) console.error(`cgc-host: 确认弹窗出错（zenity，退出码 ${code}）：${err.trim()}`);
      return "deny";
    }
    // osascript 取消以 -128 退出；cscript 正常收尾
    if (code !== 0 && !signal.aborted && !err.includes("(-128)")) console.error(`cgc-host: 确认弹窗出错（${argv[0]}，退出码 ${code}）：${err.trim()}`);
    return out.trim();
  } finally {
    if (scriptFile) rmSync(scriptFile, { force: true });
  }
};
