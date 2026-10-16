import { afterEach, expect, test } from "bun:test";
import { copyFileSync, readFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { version } from "../package.json";
import protocol from "../protocol.json";

const homes: string[] = [];
const servers: ReturnType<typeof Bun.serve>[] = [];
afterEach(() => {
  for (const server of servers.splice(0)) server.stop(true);
  for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true });
});
const bundle = "test Host bundle";
const sha256 = new Bun.CryptoHasher("sha256").update(bundle).digest("hex");
const manifest = { version, sha256, download_path: "/ext/cgc-host/cgc-host.js" };

async function gate(body: unknown, status = 200, localVersion = version, minimum = "0.1.0", offline = false) {
  const root = mkdtempSync(join(tmpdir(), "host-version-gate-"));
  homes.push(root);
  const home = join(root, "cgc-host");
  mkdirSync(join(home, "scripts"), { recursive: true });
  mkdirSync(join(root, "web/lib"), { recursive: true });
  copyFileSync(join(import.meta.dir, "../scripts/check-version-bump.ts"), join(home, "scripts/check-version-bump.ts"));
  // Exercise the actual CLI with isolated manifest inputs, never mutate repository versions.
  const policy = readFileSync(join(import.meta.dir, "../../web/lib/host-version.ts"), "utf8");
  const declaration = /export const MIN_HOST_VERSION = "[^"]+";/;
  expect(policy).toMatch(declaration);
  writeFileSync(join(root, "web/lib/host-version.ts"), policy.replace(declaration, `export const MIN_HOST_VERSION = ${JSON.stringify(minimum)};`));
  writeFileSync(join(home, "package.json"), JSON.stringify({ version: localVersion }));
  writeFileSync(join(home, "protocol.json"), JSON.stringify(protocol));
  writeFileSync(join(home, "bundle.js"), bundle);
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response(typeof body === "string" ? body : JSON.stringify(body), { status }) });
  servers.push(server);
  const url = `http://127.0.0.1:${server.port}/manifest`;
  if (offline) server.stop(true);
  const child = Bun.spawn([process.execPath, join(home, "scripts/check-version-bump.ts"), join(home, "bundle.js")], {
    env: { ...process.env, CGC_HOST_MANIFEST_URL: url }, stdout: "pipe", stderr: "pipe",
  });
  const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
  return { code, output: stdout + stderr };
}

test("only explicit 404 permits first publication", async () => {
  expect((await gate("missing", 404)).code).toBe(0);
  for (const status of [401, 403, 429, 500, 503]) {
    const result = await gate(manifest, status);
    expect(result.code).toBe(1);
    expect(result.output).toContain(`HTTP ${status}`);
  }
});
test("network failure fails closed with an actionable diagnostic", async () => {
  const result = await gate(manifest, 200, version, "0.1.0", true);
  expect(result.code).toBe(1);
  expect(result.output).toMatch(/重试|检查/);
});
test.each(["not json", null, {}, { ...manifest, version: "" }, { ...manifest, version: "v1.0.0" },
  { ...manifest, version: "0.0.0", sha256: "wrong" }, { ...manifest, download_path: "/wrong.js" }])("invalid online manifest fails closed: %j", async (body) => {
  expect((await gate(body)).code).toBe(1);
});
test("unchanged bytes need no bump; changed bytes require a different valid version", async () => {
  expect((await gate(manifest)).code).toBe(0);
  expect((await gate({ ...manifest, sha256: "0".repeat(64) })).code).toBe(1);
  expect((await gate({ ...manifest, version: "0.0.0", sha256: "0".repeat(64) })).code).toBe(0);
});
test.each([
  ["0.1.10", "0.1.10", 0], ["0.1.9", "0.1.10", 0], ["0.1.10", "0.1.9", 1],
  ["0.1.0", "0.1", 1], ["01.0.0", "1.0.0", 1], ["1.0.0-beta", "1.0.0", 1], ["1.0.0", "wat", 1],
] as const)("real gate enforces minimum %s <= package %s (exit %i)", async (minimum, packaged, code) => {
  expect((await gate({ ...manifest, version: packaged }, 200, packaged, minimum)).code).toBe(code);
  // An unavailable initial manifest must not bypass the local compatibility contract.
  expect((await gate("missing", 404, packaged, minimum)).code).toBe(code);
});
