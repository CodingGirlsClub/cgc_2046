// config.ts — 构建时写入的常量（KTD4）：可信站点来源与平台 API 地址只从这里来，任何 RPC 都改不了
import { version } from "../package.json";
import { port } from "../protocol.json";

// 发布构建用 `bun build --define CGC_SITE_ORIGIN='"…"' --define CGC_API_BASE='"…"'` 把这两个标识符
// 替换成生产值的字面量；这里是注入的唯一入口。未注入时（bun test、本地开发）标识符不存在，退回本地开发值。
// 刻意不读环境变量等运行时输入：可信来源只能来自构建。
declare const CGC_SITE_ORIGIN: string;
declare const CGC_API_BASE: string;

export const SITE_ORIGIN = typeof CGC_SITE_ORIGIN === "string" ? CGC_SITE_ORIGIN : "http://localhost:3000";
export const API_BASE = typeof CGC_API_BASE === "string" ? CGC_API_BASE : "http://localhost:4000";
export const PORT = port;
export const HOST_VERSION = version;
