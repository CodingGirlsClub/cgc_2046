import { expect, test } from "bun:test";
import protocol from "../protocol.json";
import { version } from "../package.json";
import { MIN_HOST_VERSION, assertHostVersionContract, compareHostVersions, parseHostVersion } from "../../web/lib/host-version";

test("actual minimum/package and Host preparation budget form a compatible release", () => {
  expect(() => assertHostVersionContract(MIN_HOST_VERSION, version)).not.toThrow();
  expect(Number.isSafeInteger(protocol.preparationTimeoutMs)).toBe(true);
  expect(protocol.preparationTimeoutMs).toBeGreaterThan(0);
});
test.each([
  ["0.1.9", "0.1.10", -1], ["0.1.10", "0.1.9", 1], ["1.0.0", "0.99.99", 1], ["0.1.0", "0.1.0", 0],
] as const)("numeric comparison %s vs %s", (a, b, result) => {
  expect(compareHostVersions(a, b)).toBe(result);
  if (result > 0) expect(() => assertHostVersionContract(a, b)).toThrow();
  else expect(() => assertHostVersionContract(a, b)).not.toThrow();
});
test.each([null, 1, "", "1.0", "v1.0.0", "01.0.0", "1.0.0-beta", "1.0.0+meta", "1.0.9007199254740992"])("reject ambiguous version %j", (value) => {
  expect(() => parseHostVersion(value)).toThrow();
});
