// pairing.ts — 配对（KTD3）：向平台核实学习凭证、本机确认弹窗、浏览器密钥；平台调用也供连接时的核实（KTD16）用
import { createHash, randomBytes } from "node:crypto";
import { isUuid } from "./security";
import { dialogCommand } from "./platform-dialog";
import type { Pairing } from "./state";

/** 跑一次确认弹窗：argv 交给 Bun.spawn，返回 stdout；signal 中止即关掉弹窗。测试注入替身，不弹真窗 */
export type DialogRunner = (argv: string[], signal: AbortSignal) => Promise<string>;

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
  /** 弹窗按哪个系统挑（默认 process.platform）；测试注入固定值，跨平台断言不随测试机漂移 */
  platform?: NodeJS.Platform;
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
      // 冷却从受理开始（而不是弹窗关闭）：无效 token / 平台不可达的早退同样受限，
      // 避免同源页面反复驱动 Host 调平台 /mcp/token。
      cooldownUntil = Date.now() + deps.cooldownMs;

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
          : await deps.runDialog(dialogCommand(deps.platform ?? process.platform, identity ?? start!, params.locale), signal).catch((e) => {
              console.error("cgc-host: 确认弹窗无法启动", e);
              return "deny";
            });
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
