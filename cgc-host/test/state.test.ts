// state.test.ts — 状态文件的形状与迁移：旧形状读时迁移并落盘；畸形字段当「没有」，不把垃圾写回
import { afterEach, expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { loadState, stateDir } from "../src/state";
import { cleanup, tempHome } from "./helpers";

afterEach(cleanup);

const write = (home: string, state: unknown) => {
	mkdirSync(stateDir(home), { recursive: true });
	writeFileSync(join(stateDir(home), "state.json"), JSON.stringify(state));
};
const read = (home: string) => JSON.parse(readFileSync(join(stateDir(home), "state.json"), "utf8"));

const COURSE = "11111111-1111-4111-8111-111111111111";

test("旧形状（courseId → sessionId）读成缺省 agent 的指针，并落成新形状", () => {
	const home = tempHome();
	write(home, { pairing: null, sessions: { [COURSE]: "session-1" } });

	const state = loadState(home);
	expect(state.sessions[COURSE]).toEqual({ omp: "session-1" });
	expect(read(home).sessions[COURSE]).toEqual({ omp: "session-1" });
});

test("新形状原样读，不改写文件", () => {
	const home = tempHome();
	write(home, { pairing: null, sessions: { [COURSE]: { omp: "s-1", codex: "t-1" } }, agents: { [COURSE]: "codex" } });

	const state = loadState(home);
	expect(state.sessions[COURSE]).toEqual({ omp: "s-1", codex: "t-1" });
	expect(state.agents[COURSE]).toBe("codex");
});

test("畸形的 sessions / agents（字符串、数组）当「没有」：不按索引建桶，文件落成合法空形状", () => {
	for (const malformed of [{ sessions: "garbage" }, { sessions: ["a", "b"] }, { agents: "omp" }]) {
		const home = tempHome();
		write(home, { pairing: null, ...malformed });

		const state = loadState(home);
		expect(state.sessions).toEqual({});
		expect(state.agents).toEqual({});
		expect(read(home)).toMatchObject({ sessions: {}, agents: {} });
	}
});

test("未知 kind 的指针与非法 agents 值被丢弃", () => {
	const home = tempHome();
	write(home, { pairing: null, sessions: { [COURSE]: { plug: "s-1" } }, agents: { [COURSE]: "plug" } });

	const state = loadState(home);
	expect(state.sessions).toEqual({});
	expect(state.agents).toEqual({});
});
