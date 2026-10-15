import { afterEach, expect, spyOn, test } from "bun:test";
import { clientApp } from "../src/acp/client";
import { createRuntime } from "../src/acp/runtime";
import { cleanup, fakeAgent } from "./helpers";

afterEach(cleanup);
function runtime() {
  const fake = fakeAgent();
  const r = createRuntime({ start: fake.start, reset() {}, ready() {}, app: () => clientApp({
    update() {}, permission: async () => ({ outcome: { outcome: "cancelled" } }), question: async () => ({ action: "cancel" }),
  }) });
  return { fake, r };
}

test("absolute deadline is enforced even before the event loop can deliver the timeout callback", async () => {
  const { r } = runtime();
  let now = 0, committed = false;
  const clock = spyOn(performance, "now").mockImplementation(() => now);
  try {
    await expect(r.prepare(10, async (run) => {
      await run.agent();
      now = 11;
      await run.wait("session/new", async () => "late-result");
      committed = true;
    })).rejects.toThrow("timed out");
    expect(committed).toBe(false);
    expect(r.agent).toBeNull();
  } finally { clock.mockRestore(); r.close(); }
});

test("a request expiring while queued owns no generation and cannot retire another course's healthy agent", async () => {
  const { fake, r } = runtime();
  let release!: () => void;
  const queued = new Promise<void>((resolve) => { release = resolve; });
  try {
    const a = await r.prepare(100, (run) => run.agent());
    const pending = r.prepare(10, async (run) => { await queued; return run.agent(); });
    const result = await Promise.race([
      pending.then(() => "unexpected success", (error) => String(error)),
      Bun.sleep(100).then(() => "missing bounded queue failure"),
    ]);
    expect(result).toContain("timed out (queue");
    expect(r.agent).toBe(a);
    release();
    expect(await r.prepare(100, (run) => run.agent())).toBe(a);
    expect(fake.starts).toBe(1);
  } finally { release(); r.close(); }
});
