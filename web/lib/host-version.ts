export const MIN_HOST_VERSION = "0.1.0";

/** Host releases use stable major.minor.patch only; no prefix, leading zero, prerelease or build suffix. */
export function parseHostVersion(value: unknown): number[] {
  if (typeof value !== "string" || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value)) {
    throw new Error("Host version must be stable major.minor.patch");
  }
  const parts = value.split(".").map(Number);
  if (!parts.every(Number.isSafeInteger)) throw new Error("Host version components must be safe integers");
  return parts;
}

export function compareHostVersions(left: unknown, right: unknown): number {
  const a = parseHostVersion(left), b = parseHostVersion(right);
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

export function assertHostVersionContract(minimum: unknown, packaged: unknown): void {
  if (compareHostVersions(minimum, packaged) > 0) throw new Error("MIN_HOST_VERSION exceeds the packaged Host version");
}
