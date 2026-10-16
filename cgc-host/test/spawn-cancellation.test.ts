import { afterEach, expect, test } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { clientApp, spawnOmp } from "../src/acp/client";
import { cleanup, tempHome, until } from "./helpers";

afterEach(cleanup);
const app = () => clientApp({ update() {}, permission: async () => ({ outcome: { outcome: "cancelled" } }), question: async () => ({ action: "cancel" }) });

test("aborted startup never launches a process", () => {
  const home = tempHome(), script = join(home, "fake-omp"), marker = join(home, "started");
  writeFileSync(script, '#!/bin/sh\necho started > "$MARKER"\n', { mode: 0o700 });
  const abort = new AbortController(); abort.abort();
  expect(() => spawnOmp({ path: script, env: { MARKER: marker }, envError: null }, app(), home, abort.signal)).toThrow();
  expect(existsSync(marker)).toBe(false);
});

test("retiring a generation kills even a child that ignores SIGTERM (isolated shell, no model)", async () => {
  const home = tempHome(), script = join(home, "fake-omp"), marker = join(home, "pid");
  writeFileSync(script, '#!/bin/sh\ntrap "" TERM\necho $$ > "$MARKER"\nexec /bin/sleep 60\n', { mode: 0o700 });
  const abort = new AbortController();
  const a = spawnOmp({ path: script, env: { MARKER: marker }, envError: null }, app(), home, abort.signal);
  try {
    await until(() => existsSync(marker));
    const pid = Number(readFileSync(marker, "utf8").trim());
    abort.abort();
    await a.closed;
    await until(() => { try { process.kill(pid, 0); return false; } catch { return true; } });
    expect(abort.signal.aborted).toBe(true);
  } finally {
    abort.abort(); a.close();
  }
});
