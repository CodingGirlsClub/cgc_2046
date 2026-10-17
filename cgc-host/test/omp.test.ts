// omp.test.ts — KTD12：从登录 shell 解析环境（标记之间才算数、限时、失败退回最小环境），在它的 PATH 里找 omp；按需重解析并限频
import { afterEach, expect, test } from "bun:test";
import { chmodSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ompLocator, resolveOmp } from "../src/agents/omp";
import { cleanup, tempHome } from "./helpers";

afterEach(cleanup);

/** 假的登录 shell：以 [-i, -l, -c, 命令] 被调用；body 决定它怎么表现 */
function fakeShell(body: string) {
  const dir = tempHome();
  const omp = join(dir, "omp");
  writeFileSync(omp, "#!/bin/sh\n");
  chmodSync(omp, 0o755);
  const shell = join(dir, "shell");
  writeFileSync(shell, `#!/bin/sh\n${body.replaceAll("$DIR", dir)}\n`);
  chmodSync(shell, 0o755);
  return { shell, omp };
}

test("rc 文件的输出噪音被标记隔开：环境取自登录 shell，omp 在它的 PATH 里找", async () => {
  const { shell, omp } = fakeShell(`echo "Welcome! rc noise"\nexport FROM_LOGIN_SHELL=1 PATH="$DIR:/usr/bin:/bin"\nexec /bin/sh -c "$4"\necho trailing noise`);
  const found = await resolveOmp(shell);
  expect(found.envError).toBeNull();
  expect(found.env.FROM_LOGIN_SHELL).toBe("1");
  expect(found.path).toBe(omp);
});

test.each([
  ["超时：杀掉 shell，退回 Host 自己的环境", "sleep 5", "timeout"],
  ["没打出标记就退出", "exit 1", "failed"],
] as const)("%s", async (_, body, envError) => {
  const { shell } = fakeShell(body);
  const found = await resolveOmp(shell, 200);
  expect(found.envError).toBe(envError);
  expect(found.env).toBe(process.env as Record<string, string>);
});

test("ompLocator：找不到 omp 时按需重解析，限频；找到后 present 为 true", async () => {
  let calls = 0;
  let path: string | null = null;
  const omp = ompLocator(async () => ({ path, env: {}, envError: calls++ === 0 ? "timeout" : null }), 100);
  expect(omp.present()).toBe(false); // 第一次读即触发解析
  await Bun.sleep(10);
  expect(calls).toBe(1);
  expect(omp.envError()).toBe("timeout");
  omp.present();
  await Bun.sleep(10);
  expect(calls).toBe(1); // 限频期内不再解析

  path = "/opt/homebrew/bin/omp"; // 学员装上了 OMP
  await Bun.sleep(100);
  expect(omp.present()).toBe(false);
  await Bun.sleep(10);
  expect(calls).toBe(2);
  expect(omp.present()).toBe(true);
  expect(omp.envError()).toBeNull();
});
