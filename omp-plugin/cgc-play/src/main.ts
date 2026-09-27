// main.ts — cgc-play 入口。`cgc-play [--location <location.json>]`，缺省载入内置的潜水课 c21「急救甲板」。

import { readFileSync } from "fs";
import { dirname, join } from "path";
import c21 from "../fixtures/c21/location.json";
import c21Initial from "../fixtures/c21/initial.png" with { type: "file" };
import c21Worse from "../fixtures/c21/worse.png" with { type: "file" };
import { Session } from "./engine";
import { validateLocation, type Location } from "./location";
import { serve } from "./server";
import { runUi, type SceneImages } from "./ui";

async function load(): Promise<{ loc: Location; images: SceneImages }> {
  const i = process.argv.indexOf("--location");
  if (i === -1) {
    // ponytail: 内置样板只有 c21 一个地点，多地点时改成按 location id 查表
    const files: Record<string, string> = { "initial.png": c21Initial, "worse.png": c21Worse };
    return { loc: c21 as Location, images: await readImages(c21 as Location, (f) => files[f]) };
  }
  const file = process.argv[i + 1];
  if (!file) fail("--location 需要一个 location.json 路径");
  let loc: unknown;
  try {
    loc = JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    fail(`读不了 ${file}：${(e as Error).message}`);
  }
  return { loc: loc as Location, images: await readImages(loc as Location, (f) => join(dirname(file), f)) };
}

async function readImages(loc: Location, resolve: (f: string) => string): Promise<SceneImages> {
  const r = validateLocation(loc);
  if (!r.ok) fail(`地点定义不合法：\n  ${r.errors.join("\n  ")}`);
  const out: SceneImages = {};
  for (const [state, f] of Object.entries(loc.scene.states)) {
    const path = resolve(f);
    if (!path) fail(`找不到情境图 ${f}`);
    out[state] = new Uint8Array(await Bun.file(path).arrayBuffer());
  }
  return out;
}

function fail(msg: string): never {
  console.error(`cgc-play：${msg}`);
  process.exit(1);
}

const { loc, images } = await load();
const session = new Session(loc);

let ui: Awaited<ReturnType<typeof runUi>> | undefined;
let server: Awaited<ReturnType<typeof serve>> | undefined;
const exit = (code = 0) => {
  server?.stop();
  process.exit(code);
};

try {
  server = await serve(session, undefined, () => ui?.render());
} catch (e) {
  fail((e as Error).message);
}
for (const sig of ["SIGTERM", "SIGHUP", "SIGINT"] as const) {
  process.on(sig, () => {
    ui?.destroy();
    exit(0);
  });
}

ui = await runUi(session, images, () => exit(0));
session.onEvent(() => ui?.render());
session.start();
ui.render();
