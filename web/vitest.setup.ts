import "@testing-library/jest-dom/vitest";

// Node 26 + 当前 happy-dom 组合下 window.localStorage/sessionStorage 缺失
// （既有 public-home / voices-wall 套件在本环境同红）。in-memory 兜底：
// 行为与规范一致（getItem/setItem/removeItem/clear/key/length），跨测试隔离
// 由 vitest 每文件新环境承担。
if (typeof window !== "undefined" && !window.localStorage) {
	class MemoryStorage implements Storage {
		private store = new Map<string, string>();
		get length() {
			return this.store.size;
		}
		key(index: number) {
			return [...this.store.keys()][index] ?? null;
		}
		getItem(key: string) {
			return this.store.has(key) ? this.store.get(key)! : null;
		}
		setItem(key: string, value: string) {
			this.store.set(key, String(value));
		}
		removeItem(key: string) {
			this.store.delete(key);
		}
		clear() {
			this.store.clear();
		}
	}
	Object.defineProperty(window, "localStorage", { value: new MemoryStorage(), configurable: true });
	Object.defineProperty(window, "sessionStorage", { value: new MemoryStorage(), configurable: true });
}
