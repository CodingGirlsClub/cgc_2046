// protocol.test.ts — protocol.json 是页面 ↔ Host 协议的单一事实源：结构合法，config.ts 的端口取自它
import { describe, expect, test } from "bun:test";
import protocol from "../protocol.json";
import { PORT } from "../src/config";

describe("protocol.json", () => {
  test("protocolVersion 是正整数", () => {
    expect(Number.isInteger(protocol.protocolVersion)).toBe(true);
    expect(protocol.protocolVersion).toBeGreaterThan(0);
  });

  test("port 是 1024–49151 内的整数（不落进 macOS 从 49152 起的临时端口段）", () => {
    expect(Number.isInteger(protocol.port)).toBe(true);
    expect(protocol.port).toBeGreaterThanOrEqual(1024);
    expect(protocol.port).toBeLessThanOrEqual(49151);
  });

  test.each(["pageToHost", "hostToPage"] as const)("%s 的方法名非空且不重复", (direction) => {
    const names: unknown[] = protocol.methods[direction];
    expect(names.length).toBeGreaterThan(0);
    expect(names.filter((n) => typeof n !== "string" || n.trim() === "")).toEqual([]);
    expect(names.filter((n, i) => names.indexOf(n) !== i)).toEqual([]);
  });
});

test("config.ts 的端口与 protocol.json 一致", () => {
  expect(PORT).toBe(protocol.port);
});
