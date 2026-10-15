// pairing.ts — 配对（KTD3）：向平台核实学习凭证、本机确认弹窗、浏览器密钥；平台调用也供连接时的核实（KTD16）用
import { createHash, randomBytes } from "node:crypto";
import { isUuid } from "./security";
import type { Pairing } from "./state";

/** 跑一次确认弹窗：argv 交给 Bun.spawn，返回 stdout；signal 中止即关掉弹窗。测试注入替身，不弹真窗 */
export type DialogRunner = (argv: string[], signal: AbortSignal) => Promise<string>;

/**
 * 固定的弹窗脚本：文字全部经 argv 传入（osascript 的 `--` 之后），从不拼进脚本源码——
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

type Account = Pick<Pairing, "displayName" | "maskedIdentifier">;

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

export function dialogArgv(account: Account, locale: unknown): string[] {
  const copy = COPY[locale === "en" ? "en" : "zh-CN"];
  return ["/usr/bin/osascript", "-e", DIALOG_SCRIPT, "--", copy.body(copy.account(account)), copy.title, copy.deny, copy.allow, String(DIALOG_SECONDS)];
}

/** 真实的弹窗：LaunchAgent 下的 osascript 能弹出并置前（U5 真机核验）。取消、被杀、出错都不会得到 "allow" */
export const runOsascript: DialogRunner = async (argv, signal) => {
  const proc = Bun.spawn(argv, { stdout: "pipe", stderr: "pipe", signal });
  const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  if ((await proc.exited) !== 0 && !signal.aborted && !err.includes("(-128)")) console.error(`cgc-host: 确认弹窗出错：${err.trim()}`);
  return out.trim();
};

export const newBrowserKey = () => randomBytes(32).toString("base64url");
export const hashBrowserKey = (key: string) => createHash("sha256").update(key).digest("hex");

const PLATFORM_TIMEOUT_MS = 10_000;

/** GET /mcp/token 核实出的身份（U3）：弹窗只显示这里的显示名与脱敏标识 */
export type Identity = Pick<Pairing, "tokenId" | "userId" | "displayName" | "maskedIdentifier"> & { kind: string };

const nullableString = (v: unknown) => v === null || typeof v === "string";

/** 401 / 429 → "invalid"（KTD16：有效凭证不进鉴权失败限流，429 只会来自失效凭证）；网络错误、其他状态、应答不合约 → "unavailable" */
export async function verifyToken(apiBase: string, token: string): Promise<Identity | "invalid" | "unavailable"> {
  let res: Response;
  try {
    res = await fetch(`${apiBase}/mcp/token`, {
      headers: { authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(PLATFORM_TIMEOUT_MS),
    });
  } catch {
    console.error("cgc-host: 向平台核实凭证失败（网络错误）");
    return "unavailable";
  }
  if (res.status === 401 || res.status === 429) return "invalid";
  const body = res.ok ? await res.json().catch(() => null) : null;
  if (
    typeof body?.token_id !== "string" ||
    !isUuid(body.user_id) || // user_id 会进工作目录路径
    typeof body.kind !== "string" ||
    !nullableString(body.display_name) ||
    !nullableString(body.masked_identifier)
  ) {
    console.error(`cgc-host: 向平台核实凭证失败（HTTP ${res.status}）`);
    return "unavailable";
  }
  return {
    tokenId: body.token_id,
    userId: body.user_id,
    kind: body.kind,
    displayName: body.display_name,
    maskedIdentifier: body.masked_identifier,
  };
}

/**
 * 自撤销：DELETE /mcp/token 只作用于出示的这枚凭证。尽力而为——失败只记日志、返回 false（卸载据此提示学员到页面撤销）；
 * 401 表示它本就失效了，算成功
 */
export async function revokeToken(apiBase: string, token: string): Promise<boolean> {
  const status = await fetch(`${apiBase}/mcp/token`, {
    method: "DELETE",
    headers: { authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(PLATFORM_TIMEOUT_MS),
  }).then(
    (r) => r.status,
    () => 0,
  );
  if (status !== 204 && status !== 401) console.error(`cgc-host: 自撤销凭证失败（${status ? `HTTP ${status}` : "网络错误"}）`);
  return status === 204 || status === 401;
}

export type PairOutcome =
  | { allowed: true; browserKey: string }
  | { allowed: false }
  | { error: "bad_request" | "not_paired" | "busy" | "invalid_token" | "platform_unavailable" };

/**
 * pair.request 的流程（KTD3）。同一时间只有一个配对在进行（从核实到弹窗关闭），每次弹窗之后再冷却一段时间。
 * - 带 token：平台核实 → kind 必须是 learning_host → 弹窗点名平台返回的账号 → 允许则保存（替换的是另一枚就先用旧凭证自撤销），
 *   拒绝、超时、取消则用这枚凭证自撤销；核实不通过时什么都不存、也不撤销（401 撤不动；别的 kind 可能是学员终端的 token）。
 * - 不带 token：本机已配对时，弹窗点名已存的账号，允许只换发浏览器密钥，不碰平台。
 * 允许即生成新的浏览器密钥，覆盖旧哈希——这台 Host 之前的浏览器密钥全部失效。
 */
export function createPairing(deps: {
  apiBase: string;
  runDialog: DialogRunner;
  cooldownMs: number;
  getPairing(): Pairing | null;
  setPairing(pairing: Pairing | null): void;
}) {
  let pending: { owner: unknown; controller: AbortController } | null = null;
  let cooldownUntil = 0;

  return {
    /** 只取消 owner 自己发起的那次 */
    cancel(owner: unknown) {
      if (pending && pending.owner === owner) pending.controller.abort();
    },

    async request(owner: unknown, params: Record<string, unknown>): Promise<PairOutcome> {
      const { token } = params;
      // 学习凭证的明文前缀是 cgch_；终端 token（cgc_）连平台都不必问
      if (token !== undefined && (typeof token !== "string" || !token.startsWith("cgch_"))) return { error: "bad_request" };
      const start = deps.getPairing();
      if (token === undefined && !start) return { error: "not_paired" };
      if (pending || Date.now() < cooldownUntil) return { error: "busy" };

      const controller = new AbortController();
      pending = { owner, controller };
      const { signal } = controller;
      try {
        let identity: Identity | undefined;
        if (token !== undefined) {
          const verdict = await verifyToken(deps.apiBase, token);
          if (verdict === "unavailable") return { error: "platform_unavailable" };
          if (verdict === "invalid" || verdict.kind !== "learning_host") return { error: "invalid_token" };
          identity = verdict;
        }
        const answer = signal.aborted
          ? "deny"
          : await deps.runDialog(dialogArgv(identity ?? start!, params.locale), signal).catch((e) => {
              console.error("cgc-host: 确认弹窗无法启动", e);
              return "deny";
            });
        cooldownUntil = Date.now() + deps.cooldownMs;

        if (answer !== "allow") {
          if (token !== undefined) await revokeToken(deps.apiBase, token);
          return { allowed: false };
        }
        const browserKey = newBrowserKey();
        const browserKeyHash = hashBrowserKey(browserKey);
        const current = deps.getPairing();
        if (identity) {
          if (current && current.token !== token) await revokeToken(deps.apiBase, current.token);
          const { kind: _, ...verified } = identity;
          deps.setPairing({ token: token as string, ...verified, browserKeyHash });
        } else {
          if (current !== start) return { error: "not_paired" }; // 弹窗期间本机配对被清掉了
          deps.setPairing({ ...current!, browserKeyHash });
        }
        return { allowed: true, browserKey };
      } finally {
        pending = null;
      }
    },
  };
}
