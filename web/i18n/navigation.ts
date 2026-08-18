import { createNavigation } from "next-intl/navigation";
import { routing } from "./routing";

/**
 * next-intl 导航 API（locale 感知的 Link/router 等）。
 *
 * Phase 1 只在壳层与切换器相关处使用；Phase 2 存量抽取时全站 Link 逐步替换。
 * usePathname 返回不带 locale 前缀的内部路径，切换 locale 时可直接复用。
 */
export const { Link, redirect, usePathname, useRouter, getPathname } =
	createNavigation(routing);
