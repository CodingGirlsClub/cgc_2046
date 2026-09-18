/**
 * 金句墙点赞去重键（R36）：客户端生成并复用——`a:<device_uuid>`。
 *
 * 路人（未登录）按设备去重是产品口径；登录态的 `u:<user_id>` 需要账号信息，
 * 公开首页不做鉴权读取（游客页面），故统一用设备键（服务端只校验格式，
 * 去重语义由 `flashback_likes` 唯一索引兜底）。
 *
 * 持久化用 localStorage：清缓存/换设备 = 新的一票（与「按设备去重」同义）。
 * 格式与后端 `Cgc2046.Flashback.Likes` 的校验一致（`u:`/`a:` + ≤64 字符）。
 */

export const VOTER_KEY_STORAGE = "flashback.voterKey";

const VOTER_KEY_PATTERN = /^[ua]:[A-Za-z0-9_-]{1,60}$/;

/** 读取既有键；不存在/格式非法（老版本或被人为改坏）→ null */
export function readVoterKey(storage: Storage): string | null {
	try {
		const value = storage.getItem(VOTER_KEY_STORAGE);
		return value && VOTER_KEY_PATTERN.test(value) ? value : null;
	} catch {
		// 隐私模式/禁用存储：当作无键（点赞按钮不渲染）
		return null;
	}
}

/** 读取或生成（首访落盘，之后恒同键） */
export function ensureVoterKey(storage: Storage): string | null {
	const existing = readVoterKey(storage);
	if (existing) return existing;

	const id =
		typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
			? crypto.randomUUID()
			: fallbackId();

	const created = `a:${id}`;

	try {
		storage.setItem(VOTER_KEY_STORAGE, created);
	} catch {
		return null;
	}

	return created;
}

function fallbackId(): string {
	if (typeof crypto !== "undefined" && typeof crypto.getRandomValues === "function") {
		const bytes = crypto.getRandomValues(new Uint8Array(16));
		return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
	}

	return `d${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
}
