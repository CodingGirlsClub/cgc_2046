import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
	client: { query: vi.fn(), mutate: vi.fn(), refetchQueries: vi.fn() },
}));

import { client } from "./apollo-client";
import { fetchWorkflowRuns, mapWorkflowRun, parseJsonString } from "./workflows";

describe("parseJsonString（JsonString → 对象）", () => {
	it("合法 JSON 对象解析", () => {
		expect(parseJsonString('{"uppercase":{"text":"HI"}}')).toEqual({
			uppercase: { text: "HI" },
		});
	});

	it("null/undefined/空串 → {}", () => {
		expect(parseJsonString(null)).toEqual({});
		expect(parseJsonString(undefined)).toEqual({});
		expect(parseJsonString("")).toEqual({});
	});

	it("非法 JSON → {}（不抛异常）", () => {
		expect(parseJsonString("not-json")).toEqual({});
		expect(parseJsonString("{broken")).toEqual({});
	});

	it("JSON 数组/标量 → {}（facts 契约是对象）", () => {
		expect(parseJsonString("[1,2]")).toEqual({});
		expect(parseJsonString('"str"')).toEqual({});
	});
});

describe("mapWorkflowRun（后端 WorkflowRun → 前端展示项）", () => {
	it("facts JsonString 解析为对象，status/startedAt 直传", () => {
		const item = mapWorkflowRun({
			id: "run_1",
			workspaceId: "ws_1",
			definitionId: "def_1",
			definitionVersion: 1,
			status: "succeeded",
			inputSnapshot: null,
			facts: '{"uppercase":{"text":"HI"}}',
			partitionId: "ws_1",
			version: 3,
			startedAt: "2026-08-06T10:00:00Z",
			finishedAt: "2026-08-06T10:00:05Z",
		});

		expect(item.id).toBe("run_1");
		expect(item.status).toBe("succeeded");
		expect(item.definitionId).toBe("def_1");
		expect(item.facts).toEqual({ uppercase: { text: "HI" } });
		expect(item.startedAt).toBe("2026-08-06T10:00:00Z");
		expect(item.finishedAt).toBe("2026-08-06T10:00:05Z");
	});

	it("facts 为 null → {}（无产物 run）", () => {
		const item = mapWorkflowRun({
			id: "run_2",
			workspaceId: "ws_1",
			definitionId: "def_1",
			definitionVersion: 1,
			status: "pending",
			inputSnapshot: null,
			facts: null,
			partitionId: "ws_1",
			version: 0,
			startedAt: null,
			finishedAt: null,
		});

		expect(item.facts).toEqual({});
		expect(item.startedAt).toBeNull();
	});
});

describe("fetchWorkflowRuns（#40：filter eq 包装 + 分页）", () => {
	const queryMock = vi.mocked(client.query);
	const opName = (query: unknown): string | undefined => {
		const q = query as { definitions?: Array<{ name?: { value?: string } }> };
		return q.definitions?.[0]?.name?.value;
	};

	beforeEach(() => {
		queryMock.mockReset();
	});

	it("默认调用传 first: 50、filter 只含 workspaceId eq，返回映射后的 run 列表", async () => {
		queryMock.mockImplementation(({ query, variables }) => {
			expect(opName(query)).toBe("ListWorkflowRuns");
			expect(variables).toEqual({
				filter: { workspaceId: { eq: "ws_1" } },
				first: 50,
			});
			return Promise.resolve({
				data: {
					listWorkflowRuns: {
						count: 2,
						results: [
							{
								id: "run_1",
								workspaceId: "ws_1",
								definitionId: "def_1",
								definitionVersion: 1,
								status: "succeeded",
								inputSnapshot: null,
								facts: '{"uppercase":{"text":"HI"}}',
								partitionId: "ws_1",
								version: 3,
								startedAt: "2026-08-06T10:00:00Z",
								finishedAt: "2026-08-06T10:00:05Z",
							},
							{
								id: "run_2",
								workspaceId: "ws_1",
								definitionId: "def_1",
								definitionVersion: 1,
								status: "pending",
								inputSnapshot: null,
								facts: null,
								partitionId: "ws_1",
								version: 0,
								startedAt: null,
								finishedAt: null,
							},
						],
						startKeyset: "k1",
						endKeyset: "k2",
					},
				},
			} as never);
		});

		const runs = await fetchWorkflowRuns("ws_1");
		expect(runs).toHaveLength(2);
		expect(runs[0].facts).toEqual({ uppercase: { text: "HI" } });
		expect(runs[1].facts).toEqual({});
	});

	it("带 after 时透传分页游标", async () => {
		queryMock.mockImplementation(({ variables }) => {
			expect(variables).toEqual({
				filter: { workspaceId: { eq: "ws_1" } },
				first: 50,
				after: "k1",
			});
			return Promise.resolve({
				data: { listWorkflowRuns: { count: 0, results: [] } },
			} as never);
		});

		const runs = await fetchWorkflowRuns("ws_1", { after: "k1" });
		expect(runs).toEqual([]);
	});

	it("后端返回空/缺 results → []", async () => {
		queryMock.mockResolvedValue({ data: { listWorkflowRuns: null } } as never);
		expect(await fetchWorkflowRuns("ws_1")).toEqual([]);
	});
});
