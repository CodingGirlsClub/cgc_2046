// server.test.ts — socket 分帧、事件广播、单实例与权限
import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { Session } from "../src/engine";
import type { Location } from "../src/location";
import { serve } from "../src/server";

const loc = (): Location => ({
  version: 0,
  location: "x1",
  region: "r1",
  title: "测试地点",
  unlock_after: [],
  scene: { initial: "initial", states: { initial: "a.png" } },
  stages: [
    { checklist: "x1-1", mode: "hand", kind: "select", prompt: "选", answer: ["甲"], distractors: [] },
    { checklist: "x1-2", mode: "mouth", prompt: "为什么", judge_questions: ["是否说明了原因"] },
  ],
});

let dir = "";
let stop = () => {};
afterEach(() => {
  stop();
  rmSync(dir, { recursive: true, force: true });
});

async function client(path: string) {
  const got: any[] = [];
  let buf = "";
  const sock = await Bun.connect({
    unix: path,
    socket: {
      data(_s, d) {
        const lines = (buf + d.toString()).split("\n");
        buf = lines.pop() ?? "";
        for (const l of lines) if (l) got.push(JSON.parse(l));
      },
    },
  });
  const waitFor = async (pred: (m: any) => boolean) => {
    for (let i = 0; i < 100; i++) {
      const m = got.find(pred);
      if (m) return m;
      await Bun.sleep(10);
    }
    throw new Error("timeout; got " + JSON.stringify(got));
  };
  return { sock, got, waitFor };
}

async function setup() {
  dir = mkdtempSync(join(tmpdir(), "cgc-play-"));
  const path = join(dir, "sub", "play.sock");
  const s = new Session(loc(), (xs) => xs);
  s.start();
  const srv = await serve(s, path);
  stop = srv.stop;
  return { s, path, srv };
}

describe("serve", () => {
  test("一次写入多条请求、一条请求分两次写入，都能正确分帧应答", async () => {
    const { path } = await setup();
    const c = await client(path);
    c.sock.write('{"id":1,"op":"state"}\n{"id":2,"op":"nope"}\n{"id":3,');
    await Bun.sleep(20);
    c.sock.write('"op":"state"}\n');
    expect((await c.waitFor((m) => m.id === 1)).ok).toBe(true);
    expect((await c.waitFor((m) => m.id === 2)).ok).toBe(false);
    expect((await c.waitFor((m) => m.id === 3)).ok).toBe(true);
  });

  test("引擎事件广播给已连接的客户端", async () => {
    const { s, path, srv } = await setup();
    const c = await client(path);
    for (let i = 0; i < 50 && srv.clientCount() === 0; i++) await Bun.sleep(10);
    s.pick("甲");
    const ev = await c.waitFor((m) => m.ev === "mouth_stage");
    expect(ev.checklist).toBe("x1-2");
  });

  test("新客户端连上时补发未完成的口头关卡事件（重连 / 首关即口头关卡不卡死）", async () => {
    dir = mkdtempSync(join(tmpdir(), "cgc-play-"));
    const path = join(dir, "play.sock");
    const l = loc();
    l.stages = [l.stages[1]]; // 首关即口头关卡：事件在任何客户端连上之前就已发出
    const s = new Session(l);
    s.start();
    const srv = await serve(s, path);
    stop = srv.stop;
    const c = await client(path);
    expect((await c.waitFor((m) => m.ev === "mouth_stage")).checklist).toBe("x1-2");
  });

  test("手关卡期间连上的客户端不收到补发事件", async () => {
    const { path } = await setup();
    const c = await client(path);
    c.sock.write('{"id":1,"op":"state"}\n');
    await c.waitFor((m) => m.id === 1);
    expect(c.got.some((m) => m.ev)).toBe(false);
  });

  test("已存在的宽松目录被收紧为 0700", async () => {
    dir = mkdtempSync(join(tmpdir(), "cgc-play-"));
    const sub = join(dir, "loose");
    mkdirSync(sub, { mode: 0o755 });
    const s = new Session(loc());
    s.start();
    const srv = await serve(s, join(sub, "play.sock"));
    stop = srv.stop;
    expect(statSync(sub).mode & 0o777).toBe(0o700);
  });

  test("socket 权限 0600", async () => {
    const { path } = await setup();
    expect(statSync(path).mode & 0o777).toBe(0o600);
  });

  test("已有活进程时拒绝第二个实例", async () => {
    const { path } = await setup();
    const s2 = new Session(loc());
    expect(serve(s2, path)).rejects.toThrow("已有一个 cgc-play 在运行");
  });

  test("死 socket 文件被清理后正常启动", async () => {
    dir = mkdtempSync(join(tmpdir(), "cgc-play-"));
    const path = join(dir, "play.sock");
    writeFileSync(path, "");
    const s = new Session(loc());
    s.start();
    const srv = await serve(s, path);
    stop = srv.stop;
    const c = await client(path);
    c.sock.write('{"id":9,"op":"state"}\n');
    expect((await c.waitFor((m) => m.id === 9)).ok).toBe(true);
  });
});
