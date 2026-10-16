// security.ts — 信任边界上的判定（KTD4）：每个请求的 Host / Origin 关口，进入路径的 id，成为平台备注的设备名
import { SITE_ORIGIN } from "./config";

/**
 * 每个 HTTP 请求与 WS 升级都先过这里：
 * - Host 必须是本机回环地址加本端口：DNS rebinding 时浏览器带的是攻击者域名，挡在这一步；
 * - Origin 必须精确等于构建时写入的站点来源：缺失、`null`、其他站点、localhost 的各种变体都不相等。
 *   可信来源只来自 config.ts，绝不取请求自己带来的值。
 */
export function isAllowedRequest(req: Request, port: number): boolean {
  const host = req.headers.get("host");
  return (host === `127.0.0.1:${port}` || host === `localhost:${port}`) && req.headers.get("origin") === SITE_ORIGIN;
}

// 平台的 id 一律是小写 UUID；只认这一种写法，同一门课不会因大小写落到两个目录
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export const isUuid = (value: unknown): value is string => typeof value === "string" && UUID.test(value);

/** 设备名会成为平台上的 token 备注（平台上限 80 字符）：去掉控制字符，按码点截断，不切开代理对 */
export const sanitizeDeviceName = (raw: string) => [...raw.replace(/\p{Cc}/gu, "")].slice(0, 80).join("");

/** 外来 JSON 是不是普通对象（不是 null、不是数组）：页面帧的信封与提问卡片的作答都先过这一关 */
export const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
