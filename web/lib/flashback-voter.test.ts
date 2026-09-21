import { describe, expect, it, vi } from "vitest";
import { VOTER_KEY_STORAGE, ensureVoterKey, readVoterKey } from "./flashback-voter";

/**
 * R36 点赞去重键：首访生成并落盘、之后恒同键；格式非法视为无键。
 */

class MemoryStorage implements Storage {
	private map = new Map<string, string>();
	get length() {
		return this.map.size;
	}
	clear() {
		this.map.clear();
	}
	getItem(key: string) {
		return this.map.has(key) ? this.map.get(key)! : null;
	}
	key(index: number) {
		return [...this.map.keys()][index] ?? null;
	}
	removeItem(key: string) {
		this.map.delete(key);
	}
	setItem(key: string, value: string) {
		this.map.set(key, value);
	}
}

describe("flashback-voter（R36 去重键）", () => {
	it("首访生成 a:<id> 并落盘；再次调用返回同一键", () => {
		const storage = new MemoryStorage();

		const created = ensureVoterKey(storage);
		expect(created).toMatch(/^a:[A-Za-z0-9_-]{1,60}$/);
		expect(storage.getItem(VOTER_KEY_STORAGE)).toBe(created);

		expect(ensureVoterKey(storage)).toBe(created);
	});

	it("已落盘的键原样复用（不轮换 = 同一票）", () => {
		const storage = new MemoryStorage();
		storage.setItem(VOTER_KEY_STORAGE, "a:device-abc");

		expect(readVoterKey(storage)).toBe("a:device-abc");
		expect(ensureVoterKey(storage)).toBe("a:device-abc");
	});

	it("格式非法（老版本/被人为改坏）→ 视为无键并重新生成", () => {
		const storage = new MemoryStorage();
		storage.setItem(VOTER_KEY_STORAGE, "x:bad");
		expect(readVoterKey(storage)).toBeNull();

		const regenerated = ensureVoterKey(storage);
		expect(regenerated).toMatch(/^a:/);
		expect(readVoterKey(storage)).toBe(regenerated);
	});

	it("存储不可用（隐私模式）→ null，不抛", () => {
		const storage = new MemoryStorage();
		vi.spyOn(storage, "setItem").mockImplementation(() => {
			throw new Error("QuotaExceededError");
		});

		expect(ensureVoterKey(storage)).toBeNull();
		vi.restoreAllMocks();
	});
});
