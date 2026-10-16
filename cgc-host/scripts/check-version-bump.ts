// check-version-bump.ts — Host 的版本纪律门禁（KTD15，先例 openclacky-ext/cgc-2046/bin/check-version-bump）：
// 包内容变了而 package.json 的版本号没变，部署失败。否则 /health 报的版本号认不出是哪一份包，
// web 的 MIN_HOST_VERSION 也就没法把已装旧包的学员引去更新。
//
// 比较线上清单 cgc-host.json 与本次构建的包：
//   sha256 相同                    → 放行（内容没变，只是重建）
//   sha256 不同、版本号已变         → 放行（正常发版）
//   sha256 不同、版本号没变         → 失败
//   明确 404 → 首次发布放行；其余无法判定（网络、HTTP、JSON、字段）一律失败
// 包是单个 JS 文件，Bun 版本钉死（deploy.yml）、依赖按锁文件安装，同一份源码构建出的字节相同，
// 所以包的 sha256 就是内容指纹（扩展的 zip 带 mtime 才需要另算指纹）。
//
// 用法：bun cgc-host/scripts/check-version-bump.ts <新包路径>
// 环境变量：CGC_HOST_MANIFEST_URL 覆盖线上清单地址（测试用）
// 退出码：0 放行；1 版本契约或线上清单验证失败；2 用法错误
import { version } from "../package.json";
import { MIN_HOST_VERSION, assertHostVersionContract, parseHostVersion } from "../../web/lib/host-version";

const bundlePath = process.argv[2];
if (!bundlePath || !(await Bun.file(bundlePath).exists())) {
  console.error("用法：bun cgc-host/scripts/check-version-bump.ts <新包路径>");
  process.exit(2);
}
const local = new Bun.CryptoHasher("sha256").update(await Bun.file(bundlePath).bytes()).digest("hex");
const manifestUrl = process.env.CGC_HOST_MANIFEST_URL ?? "https://api.codingirlsclub.com/ext/cgc-host/cgc-host.json";

function fail(reason: string): never {
  console.error(`check-version-bump: ERROR ${reason}。检查版本契约、网络及发布清单后重试；未验证前不发布。`);
  process.exit(1);
}

try {
  assertHostVersionContract(MIN_HOST_VERSION, version);
} catch (e) {
  fail(`本地最低版本与待发布包不兼容：${(e as Error).message}`);
}
let res: Response;
try {
  res = await fetch(manifestUrl, { signal: AbortSignal.timeout(15_000) });
} catch {
  fail("线上清单请求失败或超过 15 秒");
}
if (res.status === 404) {
  console.warn("check-version-bump: WARN 线上清单明确 HTTP 404，按首次发布放行");
  process.exit(0);
}
if (!res.ok) fail(`线上清单 HTTP ${res.status}`);
let manifest: { version: string; sha256: string; download_path: string };
try {
  manifest = await res.json();
} catch {
  fail("线上清单不是有效 JSON");
}
try {
  parseHostVersion(manifest?.version);
} catch {
  fail("线上清单 version 格式错误，应为 major.minor.patch");
}
if (typeof manifest.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(manifest.sha256) || manifest.download_path !== "/ext/cgc-host/cgc-host.js")
  fail("线上清单 sha256 或 download_path 字段不合法");

if (manifest.sha256 === local) {
  console.log(`check-version-bump: OK 内容未变（sha256 ${local.slice(0, 12)}…），无需改版本号`);
  process.exit(0);
}
if (manifest.version !== version) {
  console.log(`check-version-bump: OK 正常发版：已发布 ${manifest.version} → 待发布 ${version}`);
  process.exit(0);
}
const message = `cgc-host 的包内容变了，但 cgc-host/package.json 的版本号没变（都是 ${version}）`;
console.error(process.env.GITHUB_ACTIONS === "true" ? `::error::${message}` : message);
console.error(`sha256：已发布 ${manifest.sha256.slice(0, 16)}… ≠ 待发布 ${local.slice(0, 16)}…
修法：提高 cgc-host/package.json 的 version。需要强制更新时，再提高 web/lib/host-version.ts 的 MIN_HOST_VERSION。`);
process.exit(1);
