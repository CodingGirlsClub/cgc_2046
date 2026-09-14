import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { act, cleanup, waitFor } from "@testing-library/react";
import { renderHook } from "@/test-utils";

/**
 * opencode 第④步授权阶段信号测试（U8，plan 2026-09-15 opencode-desktop-host）：
 * idle / pending / active 三态、enabled 门控、失败保留、focus 重查与 active 停表。
 */

const { fetchMyOauthAuthorizationsMock } = vi.hoisted(() => ({
	fetchMyOauthAuthorizationsMock: vi.fn(),
}));

vi.mock("./mcp", () => ({
	fetchMyOauthAuthorizations: fetchMyOauthAuthorizationsMock,
}));

import { useOpencodeAuthPhase } from "./use-opencode-auth-phase";
import type { OauthAuthorization } from "./graphql/oauth-authorization";

/** 授权夹具：默认 pending（同意行已存在、尚未换得凭证） */
function grant(over: Partial<OauthAuthorization>): OauthAuthorization {
	return {
		clientId: "cli_1",
		clientName: "opencode",
		scope: "cgc",
		grantedAt: null,
		lastUsedAt: null,
		status: "pending",
		...over,
	};
}

beforeEach(() => {
	vi.clearAllMocks();
	fetchMyOauthAuthorizationsMock.mockResolvedValue([]);
});

afterEach(cleanup);

describe("useOpencodeAuthPhase（U8 第④步等待态信号）", () => {
	it("无授权记录 → idle（尚未触发授权）", async () => {
		const { result } = renderHook(() => useOpencodeAuthPhase(true));

		await waitFor(() =>
			expect(fetchMyOauthAuthorizationsMock).toHaveBeenCalled(),
		);
		expect(result.current.phase).toBe("idle");
	});

	it("有同意行、尚未换得凭证 → pending（授权进行中）", async () => {
		fetchMyOauthAuthorizationsMock.mockResolvedValue([
			grant({ status: "pending" }),
		]);

		const { result } = renderHook(() => useOpencodeAuthPhase(true));

		await waitFor(() => expect(result.current.phase).toBe("pending"));
	});

	it("已有活跃授权 → active（第④步授权完成，向导完成判定）", async () => {
		fetchMyOauthAuthorizationsMock.mockResolvedValue([
			grant({ status: "active", grantedAt: "2026-09-15T10:00:00Z" }),
		]);

		const { result } = renderHook(() => useOpencodeAuthPhase(true));

		await waitFor(() => expect(result.current.phase).toBe("active"));
	});

	it("enabled=false 不读取、不轮询（非 opencode 分支与只读回看）", () => {
		renderHook(() => useOpencodeAuthPhase(false));

		expect(fetchMyOauthAuthorizationsMock).not.toHaveBeenCalled();
	});

	it("读取失败保留上一阶段（等待态不被一次网络抖动改写）", async () => {
		fetchMyOauthAuthorizationsMock.mockResolvedValue([
			grant({ status: "pending" }),
		]);
		const { result } = renderHook(() => useOpencodeAuthPhase(true));
		await waitFor(() => expect(result.current.phase).toBe("pending"));

		fetchMyOauthAuthorizationsMock.mockRejectedValue(new Error("network down"));
		act(() => result.current.recheck());

		await waitFor(() =>
			expect(fetchMyOauthAuthorizationsMock).toHaveBeenCalledTimes(2),
		);
		expect(result.current.phase).toBe("pending");
	});

	it("recheck()：授权完成后手动重查 → active（「我已授权，检查状态」）", async () => {
		const { result } = renderHook(() => useOpencodeAuthPhase(true));
		await waitFor(() => expect(result.current.phase).toBe("idle"));

		fetchMyOauthAuthorizationsMock.mockResolvedValue([
			grant({ status: "active" }),
		]);
		act(() => result.current.recheck());

		await waitFor(() => expect(result.current.phase).toBe("active"));
	});

	it("focus 重查：切回浏览器即刷新（宿主在外部完成授权）", async () => {
		const { result } = renderHook(() => useOpencodeAuthPhase(true));
		await waitFor(() => expect(result.current.phase).toBe("idle"));

		fetchMyOauthAuthorizationsMock.mockResolvedValue([
			grant({ status: "active" }),
		]);
		act(() => {
			window.dispatchEvent(new Event("focus"));
		});

		await waitFor(() => expect(result.current.phase).toBe("active"));
	});

	it("进入 active 后停表：focus 不再触发读取（终态不轮询）", async () => {
		fetchMyOauthAuthorizationsMock.mockResolvedValue([
			grant({ status: "active" }),
		]);
		const { result } = renderHook(() => useOpencodeAuthPhase(true));
		await waitFor(() => expect(result.current.phase).toBe("active"));
		const calls = fetchMyOauthAuthorizationsMock.mock.calls.length;

		act(() => {
			window.dispatchEvent(new Event("focus"));
		});

		expect(fetchMyOauthAuthorizationsMock.mock.calls.length).toBe(calls);
	});
});
