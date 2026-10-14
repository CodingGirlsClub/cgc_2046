// licenses.test.ts — 许可门禁扫的是传入的包根：共享扫描脚本若忽略这个参数，会转去扫 web 的依赖树，cgc-host 的违规依赖就此假绿
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCANNER = join(import.meta.dir, "../../web/scripts/check-licenses.mjs");

test("传入包根里的 GPL-2.0-only 依赖让扫描变红", () => {
  const root = mkdtempSync(join(tmpdir(), "cgc-host-licenses-"));
  try {
    const pkg = join(root, "node_modules/.pnpm/bad@1.0.0/node_modules/bad");
    mkdirSync(pkg, { recursive: true });
    writeFileSync(join(pkg, "package.json"), JSON.stringify({ name: "bad", license: "GPL-2.0-only" }));

    const r = Bun.spawnSync(["node", SCANNER, root]);
    expect(r.exitCode).toBe(1);
    expect(r.stderr.toString()).toContain("bad: GPL-2.0-only");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
