/**
 * 剪贴板复制助手（切片 D review 修复：三处调用点统一失败路径）。
 *
 * 返回是否成功。失败场景（非安全上下文、权限拒绝、Safari 用户手势超时、
 * API 不存在）一律返回 false 而非抛出未处理拒绝——由调用方决定如何提示用户，
 * 避免「用户以为已复制实际没有」的静默失败（对一次性明文的连接 token 尤为关键）。
 */
export async function copyText(text: string): Promise<boolean> {
	if (typeof navigator === "undefined" || !navigator.clipboard) return false;
	try {
		await navigator.clipboard.writeText(text);
		return true;
	} catch {
		return false;
	}
}
