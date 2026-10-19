// security.test.ts — 只服务本机、只服务 CGC 站点（R22、R23、KTD4；Covers AE8），以及进入路径与平台备注的值的校验
import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { networkInterfaces } from "node:os";
import { SITE_ORIGIN } from "../src/config";
import { sanitizeDeviceName } from "../src/security";
import { WORKSPACE_DIR, workDir } from "../src/state";
import { COURSE, cleanup, connect, HOST_ROOT, startHost, USER_A } from "./helpers";

afterEach(cleanup);

const reachable = (hostname: string, port: number) =>
  Bun.connect({ hostname, port, socket: { data() {} } }).then(
    (s) => {
      s.end();
      return true;
    },
    () => false,
  );

const lanIp = Object.values(networkInterfaces())
  .flat()
  .find((a) => a?.family === "IPv4" && !a.internal)?.address;

test("R23. 只绑定 127.0.0.1：绑定地址断言恒执行，局域网不可达作为附加断言", async () => {
  const host = startHost();
  // 关键断言：绑定地址本身。没有局域网 IPv4 的机器/容器上也不会空转。
  expect(host.hostname).toBe("127.0.0.1");
  expect(await reachable("127.0.0.1", host.port)).toBe(true);
  if (lanIp) expect(await reachable(lanIp, host.port)).toBe(false);
});

describe("Host 头不是本机回环地址加本端口时 403，不带 CORS 头与响应体", () => {
  test.each(["evil.example", "127.0.0.1.evil.example", "192.168.1.10"])("%s", async (name) => {
    const { port } = startHost();
    const res = await fetch(`http://127.0.0.1:${port}/health`, { headers: { Host: `${name}:${port}`, Origin: SITE_ORIGIN } });
    expect(res.status).toBe(403);
    expect(res.headers.get("access-control-allow-origin")).toBeNull();
    expect(await res.text()).toBe("");
  });

  test("对照：localhost:<port> 与 127.0.0.1:<port> 放行", async () => {
    const { port } = startHost();
    for (const name of ["localhost", "127.0.0.1"]) {
      const res = await fetch(`http://127.0.0.1:${port}/health`, { headers: { Host: `${name}:${port}`, Origin: SITE_ORIGIN } });
      expect(res.status).toBe(200);
    }
  });
});

describe("Covers AE8. Origin 不精确等于站点来源：/health 403，WS 升级被拒，不弹窗也不碰平台", () => {
  test.each([
    ["缺失", {}],
    ["null", { Origin: "null" }],
    ["其他站点", { Origin: "https://evil.example" }],
    ["localhost 换端口", { Origin: "http://localhost:3001" }],
    ["127.0.0.1 同端口", { Origin: "http://127.0.0.1:3000" }],
  ] as [string, Record<string, string>][])("%s", async (_, headers) => {
    const host = startHost();
    const res = await fetch(`http://127.0.0.1:${host.port}/health`, { headers });
    expect(res.status).toBe(403);
    expect(res.headers.get("access-control-allow-origin")).toBeNull();
    expect(await res.text()).toBe("");

    await expect(connect(host.port, headers)).rejects.toThrow("upgrade refused");
    expect(host.dialog.calls).toEqual([]);
    expect(host.platform.calls).toEqual([]);
  });

  test("对照：站点来源能完成 WS 升级", async () => {
    const { port } = startHost();
    await connect(port, { Origin: SITE_ORIGIN });
  });
});

test("发布构建经 --define 注入生产来源后，http://localhost:3000 同样被拒", () => {
  const code = `
    const { isAllowedRequest } = await import("./src/security.ts");
    const req = (origin) => new Request("http://127.0.0.1:47823/health", { headers: { host: "127.0.0.1:47823", origin } });
    console.log(JSON.stringify([isAllowedRequest(req("http://localhost:3000"), 47823), isAllowedRequest(req("https://cgc.example"), 47823)]));
  `;
  const r = Bun.spawnSync([process.execPath, "--define", 'CGC_SITE_ORIGIN="https://cgc.example"', "-e", code], { cwd: HOST_ROOT });
  expect(r.stderr.toString()).toBe("");
  expect(JSON.parse(r.stdout.toString())).toEqual([false, true]);
});

test("KTD6. 课程工作目录 ~/cgc2046_workspace/courses/<userId>/<courseId> 只接受 UUID", () => {
  expect(workDir("/home/x", USER_A, COURSE)).toBe(`/home/x/cgc2046_workspace/courses/${USER_A}/${COURSE}`);
  for (const bad of ["../../etc", `${COURSE}/..`, COURSE.toUpperCase(), ""]) {
    expect(() => workDir("/home/x", USER_A, bad)).toThrow();
    expect(() => workDir("/home/x", bad, COURSE)).toThrow();
  }
});

test("KTD6. 终端插件的工作区名与 Host 的 WORKSPACE_DIR 一致（跨包无共享，读源码钉住）", () => {
  const dir = new URL("../../omp-plugin/cgc-2046/extensions/", import.meta.url);
  const source = readFileSync(new URL("cgc-command.ts", dir), "utf8");
  // 插件的 /cgc 用这个字面量判断「在不在工作目录」，两边必须同名：否则学员按插件引导进去，Host 却把课程建在别处
  expect(source).toContain(`const workspaceDir = "~/${WORKSPACE_DIR}";`);
  expect(source).toContain(`currentDir.endsWith("/${WORKSPACE_DIR}")`);
});

test("设备名（成为平台 token 备注）去掉控制字符，按码点截到 80（平台备注上限）", () => {
  expect(sanitizeDeviceName("Mac\u0000Book\n\u001b[31m\u007f")).toBe("MacBook[31m");
  expect([...sanitizeDeviceName("😀".repeat(100))].length).toBe(80);
});
