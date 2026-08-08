/**
 * 「最近访问工作区」记忆（IA 收敛：登录后直入默认 workspace）。
 *
 * 首页 / 分发时用 readLastWorkspace 选出默认 workspace（记忆 > 第一个 active），
 * WorkspaceShell 解析到工作区时用 writeLastWorkspace 更新记忆。
 *
 * 读写范式照抄 theme-provider.tsx（window 守卫 + try/catch）：
 * - 读：SSR 安全，异常/缺失返回 null；
 * - 写：吞隐私模式等写入错误；
 * - 不做 slug 白名单校验 —— 记忆失效由 /w/[slug] 页既有「工作区不可访问」态兜底。
 */

const STORAGE_KEY = "cgc_last_workspace";

/** 读取记忆的 workspace slug（无记忆/异常时返回 null） */
export function readLastWorkspace(): string | null {
	if (typeof window === "undefined") return null;
	try {
		const slug = window.localStorage.getItem(STORAGE_KEY);
		return slug && slug.length > 0 ? slug : null;
	} catch {
		return null;
	}
}

/** 记录最近访问的 workspace slug（写入失败静默） */
export function writeLastWorkspace(slug: string): void {
	if (typeof window === "undefined") return;
	try {
		window.localStorage.setItem(STORAGE_KEY, slug);
	} catch {
		// ignore private-mode write errors
	}
}
