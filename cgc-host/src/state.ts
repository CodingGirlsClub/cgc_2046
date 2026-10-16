// state.ts — Host 的本机状态 ~/.cgc2046/host/state.json：配对记录与每门课的会话指针。
// 目录 0700、文件 0600；先写临时文件再改名，写到一半断电也不会留下半个文件。
import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isUuid } from "./security";

/** 一台 Host 同一时间只为一个账号、一个浏览器工作（术语表「已配对的电脑」）。除 token 外都来自平台的 GET /mcp/token */
export interface Pairing {
  /** 学习凭证明文：Host 要拿它调平台，只能存明文，靠文件权限保护 */
  token: string;
  tokenId: string;
  userId: string;
  displayName: string | null;
  maskedIdentifier: string | null;
  /** 浏览器密钥只存 sha256；换发即覆盖，旧密钥随之失效 */
  browserKeyHash: string;
}

export interface HostState {
  pairing: Pairing | null;
  /** KTD6：courseId → 当前 sessionId，由 U6 读写 */
  sessions: Record<string, string>;
}

export const stateDir = (home: string) => join(home, ".cgc2046", "host");
const statePath = (home: string) => join(stateDir(home), "state.json");

/** 状态文件不存在即未配对（KTD6：丢了就从新对话开始）；其他读取错误照常抛出 */
export function loadState(home: string): HostState {
  try {
    return JSON.parse(readFileSync(statePath(home), "utf8"));
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return { pairing: null, sessions: {} };
    throw e;
  }
}

export function saveState(home: string, state: HostState) {
  const dir = stateDir(home);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700); // mode 只在新建时生效；已存在的目录也收紧
  const tmp = `${statePath(home)}.tmp`;
  writeFileSync(tmp, JSON.stringify(state), { mode: 0o600 });
  renameSync(tmp, statePath(home));
}

/** KTD6：课程工作目录 ~/CGC/<userId>/<courseId>。两个 id 都必须是 UUID，页面给的任意字符串进不了路径 */
export function workDir(home: string, userId: string, courseId: string): string {
  if (!isUuid(userId) || !isUuid(courseId)) throw new Error("工作目录只接受 UUID 形式的 userId 与 courseId");
  return join(home, "CGC", userId, courseId);
}
