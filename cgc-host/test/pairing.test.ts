// pairing.test.ts — 配对（KTD3）：核实身份、本机弹窗、浏览器密钥；凭证在本机的生命周期（KTD16）；状态文件
import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { DIALOG_SCRIPT } from "../src/platform-dialog";
import { loadState, stateDir } from "../src/state";
import {
  COURSE,
  cleanup,
  connect,
  helloed,
  identity,
  pair,
  refused,
  sha256,
  startHost,
  until,
  untilAborted,
  USER_A,
  USER_B,
} from "./helpers";

afterEach(cleanup);

const TOKEN = "cgch_pairing-token";
const deletes = (host: ReturnType<typeof startHost>) => host.platform.calls.filter((c) => c.method === "DELETE");

test("凭证 kind 不是 learning_host：拒收，不弹窗，也不撤销（它可能是学员终端在用的 token）", async () => {
  const host = startHost();
  host.platform.tokens.set(TOKEN, identity(USER_A, "token-id-t", { kind: "terminal" }));
  const c = await connect(host.port);
  expect(await c.call("pair.request", { token: TOKEN })).toMatchObject(refused("invalid_token"));
  // 终端 token 的明文前缀是 cgc_：连平台都不问
  expect(await c.call("pair.request", { token: "cgc_terminal-token" })).toMatchObject(refused("bad_request"));

  expect(host.dialog.calls).toEqual([]);
  expect(host.platform.calls).toEqual([{ method: "GET", token: TOKEN }]);
  expect(loadState(host.home).pairing).toBeNull();
});

test("显示名里的引号、反斜杠与 AppleScript 原样作为一个 argv 元素到达弹窗；脚本源码固定、不含用户文字", async () => {
  const payload = `" & (do shell script "touch /tmp/pwned") & "\\ \\"`;
  const host = startHost();
  host.platform.tokens.set(TOKEN, identity(USER_A, "token-id-i", { display_name: payload }));
  const c = await connect(host.port);
  await c.call("pair.request", { token: TOKEN });

  const [argv] = host.dialog.calls;
  expect(argv.slice(0, 4)).toEqual(["/usr/bin/osascript", "-e", DIALOG_SCRIPT, "--"]);
  expect(argv[2]).not.toContain(payload);
  expect(argv.filter((a) => a.includes(payload))).toHaveLength(1);
  expect(argv.slice(4).join("\n")).toContain("a***@example.com");
  // 默认按钮（与 Esc）是第一个按钮「拒绝」，限时不答按拒绝处理
  expect(DIALOG_SCRIPT).toContain("default button 1 cancel button 1");
  expect(DIALOG_SCRIPT).toContain("giving up after");
  expect(argv[6]).toBe("拒绝");
});

test.each(["linux", "win32"] as const)("Covers 跨平台：%s 上按该系统的原装弹窗组命令；账号文字仍只经一个 argv 元素传入", async (platform) => {
  const payload = `" & (do shell script "touch /tmp/pwned") & "\\ \\"`;
  const host = startHost({ platform });
  host.platform.tokens.set(TOKEN, identity(USER_A, "token-id-x", { display_name: payload }));
  const c = await connect(host.port);
  await c.call("pair.request", { token: TOKEN });

  const [argv] = host.dialog.calls;
  expect(argv[0]).toBe(platform === "linux" ? "zenity" : "cscript");
  // 文字只出现在一个 argv 元素里，不拼进任何固定脚本
  expect(argv.filter((a) => a.includes(payload))).toHaveLength(1);
  expect(argv.join("\n")).toContain("a***@example.com");
});

test("locale 只选弹窗文案：en 出英文，白名单外的值退回 zh-CN", async () => {
  const host = startHost();
  host.platform.tokens.set(TOKEN, identity(USER_A, "token-id-l"));
  const c = await connect(host.port);
  for (const locale of ["en", "fr", undefined]) await c.call("pair.request", { token: TOKEN, locale });
  expect(host.dialog.calls.map((argv) => argv.slice(6, 8))).toEqual([
    ["Deny", "Allow"],
    ["拒绝", "允许"],
    ["拒绝", "允许"],
  ]);
});

describe("Covers AE2. 拒绝、超时、平台 401：Host 都不保存凭证", () => {
  test.each(["deny", "timeout"])("%s：回 allowed:false，并用这枚凭证自撤销一次", async (answer) => {
    const host = startHost();
    host.platform.tokens.set(TOKEN, identity(USER_A, "token-id-d"));
    host.dialog.answer = answer;
    const c = await connect(host.port);
    expect(await c.call("pair.request", { token: TOKEN })).toEqual({ method: "pair.result", id: "1", params: { allowed: false } });
    expect(deletes(host)).toEqual([{ method: "DELETE", token: TOKEN }]);
    expect(loadState(host.home).pairing).toBeNull();
  });

  test("pair.request 的冷却从受理开始：连续无效 token 不会反复打平台", async () => {
  const host = startHost({ cooldownMs: 60 });
  const c = await connect(host.port);
  expect(await c.call("pair.request", { token: "cgch_unknown-token-1" })).toMatchObject(refused("invalid_token"));
  expect(host.platform.calls).toEqual([{ method: "GET", token: "cgch_unknown-token-1" }]);

  // 冷却期内第二次请求直接 busy，不再驱动平台核实
  expect(await c.call("pair.request", { token: "cgch_unknown-token-2" })).toMatchObject(refused("busy"));
  expect(host.platform.calls).toHaveLength(1);
});

test("弹窗关闭后仍静默一段：弹窗时长超过冷却时也不允许立刻再弹", async () => {
  const host = startHost({ cooldownMs: 40 });
  host.platform.tokens.set("cgch_slow-dialog", identity(USER_A, "token-id-slow"));
  host.platform.tokens.set("cgch_second", identity(USER_A, "token-id-second"));
  host.dialog.answer = async (signal: AbortSignal) => {
    await Bun.sleep(120); // 弹窗比冷却长（生产弹窗最长 60s，冷却 3s）
    return signal.aborted ? "" : "deny";
  };
  const c = await connect(host.port);
  expect(await c.call("pair.request", { token: "cgch_slow-dialog" })).toMatchObject({ method: "pair.result", params: { allowed: false } });
  expect(await c.call("pair.request", { token: "cgch_second" })).toMatchObject(refused("busy"));
  expect(host.dialog.calls).toHaveLength(1);
});

test("GET /mcp/token 回 401：拒收，不弹窗，也不调 DELETE", async () => {
    const host = startHost();
    const c = await connect(host.port);
    expect(await c.call("pair.request", { token: TOKEN })).toMatchObject(refused("invalid_token"));
    expect(host.dialog.calls).toEqual([]);
    expect(deletes(host)).toEqual([]);
    expect(loadState(host.home).pairing).toBeNull();
  });
});

test("允许后旧浏览器密钥全部失效（含已 hello 的连接）、被替换的凭证用它自己自撤销；hello 的账号不符被拒", async () => {
  const host = startHost();
  const first = await pair(host, USER_A);
  const live = await helloed(host, first.browserKey);

  const second = await pair(host, USER_B);
  expect(deletes(host)).toEqual([{ method: "DELETE", token: first.token }]);
  expect(await live.call("chat.send", { courseId: COURSE })).toMatchObject(refused("unauthorized"));

  const c = await connect(host.port);
  expect(await c.call("hello", { userId: USER_A, browserKey: first.browserKey })).toMatchObject(refused("unauthorized"));
  expect(await c.call("hello", { userId: USER_A, browserKey: second.browserKey })).toMatchObject(refused("unauthorized"));
  expect(await c.call("hello", { userId: USER_B, browserKey: second.browserKey })).toMatchObject({
    method: "status",
    params: { state: "ready", pairedUserId: USER_B, tokenId: second.tokenId },
  });
});

test("已为同一账号配对：不带凭证的 pair.request 弹窗点名已存的账号，允许后只换发浏览器密钥", async () => {
  const host = startHost();
  const first = await pair(host);
  const before = loadState(host.home).pairing;
  const platformCalls = host.platform.calls.length;

  const c = await connect(host.port);
  const reply = await c.call("pair.request", {});
  expect(reply).toMatchObject({ method: "pair.result", params: { allowed: true } });
  const { browserKey } = reply.params;
  expect(browserKey).not.toBe(first.browserKey);
  expect(host.dialog.calls[1].slice(4).join("\n")).toContain("学员甲（a***@example.com）");
  expect(loadState(host.home).pairing).toEqual({ ...before!, browserKeyHash: sha256(browserKey) });
  expect(host.platform.calls).toHaveLength(platformCalls);

  expect(await c.call("hello", { userId: USER_A, browserKey: first.browserKey })).toMatchObject(refused("unauthorized"));
  expect(await c.call("hello", { userId: USER_A, browserKey })).toMatchObject({ params: { state: "ready" } });
});

test("未配对时不带凭证的 pair.request：not_paired，不弹窗", async () => {
  const host = startHost();
  const c = await connect(host.port);
  expect(await c.call("pair.request", {})).toMatchObject(refused("not_paired"));
  expect(host.dialog.calls).toEqual([]);
});

test("状态文件只存浏览器密钥的哈希；目录 0700、文件 0600", async () => {
  const host = startHost();
  const { browserKey } = await pair(host);
  const file = join(stateDir(host.home), "state.json");
  const content = readFileSync(file, "utf8");
  expect(content).not.toContain(browserKey);
  expect(JSON.parse(content).pairing.browserKeyHash).toBe(sha256(browserKey));
  expect(statSync(stateDir(host.home)).mode & 0o777).toBe(0o700);
  expect(statSync(file).mode & 0o777).toBe(0o600);
});

test("同一时间只有一个弹窗；pair.cancel 关掉弹窗按拒绝处理；弹窗之后冷却期内同样 busy", async () => {
  const host = startHost({ cooldownMs: 60_000 });
  host.platform.tokens.set(TOKEN, identity(USER_A, "token-id-b"));
  host.platform.tokens.set("cgch_second", identity(USER_A, "token-id-b2"));
  let dialogSignal: AbortSignal | undefined;
  host.dialog.answer = (signal) => {
    dialogSignal = signal;
    return untilAborted(signal);
  };
  const a = await connect(host.port);
  const b = await connect(host.port);

  const pending = a.call("pair.request", { token: TOKEN });
  await until(() => host.dialog.calls.length === 1);
  b.send({ method: "pair.cancel" }); // 只能取消自己发起的那次
  expect(await b.call("pair.request", { token: "cgch_second" })).toMatchObject(refused("busy"));
  expect(dialogSignal?.aborted).toBe(false);

  a.send({ method: "pair.cancel" });
  expect(await pending).toMatchObject({ method: "pair.result", params: { allowed: false } });
  expect(deletes(host)).toEqual([{ method: "DELETE", token: TOKEN }]);

  expect(await b.call("pair.request", { token: "cgch_second" })).toMatchObject(refused("busy"));
  expect(host.dialog.calls).toHaveLength(1);
  expect(host.platform.calls.some((x) => x.token === "cgch_second")).toBe(false);
});

test("pair.forget：清掉本机配对并用该凭证自撤销", async () => {
  const host = startHost();
  const { token, browserKey } = await pair(host);
  const c = await helloed(host, browserKey);
  c.send({ method: "pair.forget" });
  expect(await c.next((m) => m.method === "status" && m.params.state === "unpaired")).toBeTruthy();
  expect(loadState(host.home).pairing).toBeNull();
  await until(() => deletes(host).some((x) => x.token === token));
});

describe("KTD16. 连接 hello 后核实一次本机凭证：401 / 429 清掉，5xx 保留", () => {
  test.each([
    [401, false],
    [429, false],
    [503, true],
  ])("平台回 %d：保留 = %p", async (status, kept) => {
    const host = startHost();
    const { token, browserKey } = await pair(host);
    host.platform.tokens.set(token, { status });
    const before = host.platform.calls.length;

    const c = await connect(host.port);
    expect(await c.call("hello", { userId: USER_A, browserKey })).toMatchObject({
      method: "status",
      params: kept ? { state: "ready", pairedUserId: USER_A } : { state: "unpaired", pairedUserId: null },
    });
    expect(host.platform.calls.slice(before)).toEqual([{ method: "GET", token }]);
    expect(loadState(host.home).pairing !== null).toBe(kept);
  });
});
