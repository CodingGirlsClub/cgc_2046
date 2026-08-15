import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook, act } from "@testing-library/react";
import { useWorkspaceBySlug } from "./use-workspace-by-slug";

/**
 * useWorkspaceBySlug（#017 Bug B：网络失败 ≠ 无权限）单测。
 *
 * 覆盖成员主路径、平台管理员非成员 fallback、普通用户未知 slug、
 * 首帧 loading、slug 变化 stale、空 slug skip、reject → error、retry 重拉。
 */

const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
}));
const { fetchWorkspaceBySlug } = vi.hoisted(() => ({
	fetchWorkspaceBySlug: vi.fn(),
}));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchCurrentProfile };
});

vi.mock("@/lib/requests", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchWorkspaceBySlug };
});

beforeEach(() => {
	fetchMyWorkspaces.mockReset();
	fetchCurrentProfile.mockReset();
	fetchWorkspaceBySlug.mockReset();
	fetchCurrentProfile.mockResolvedValue({ isPlatformAdmin: false });
});

describe("useWorkspaceBySlug (#017 Bug B：网络失败 ≠ 无权限)", () => {
	it("首帧：{ ws: undefined, loading: true }（未解析完成不渲染「不存在」）", () => {
		// 永不 settle 的 promise：模拟拉取进行中（首帧不落定）
		fetchMyWorkspaces.mockReturnValue(Promise.withResolvers<void>().promise);
		const { result } = renderHook(() => useWorkspaceBySlug("cgc-academy"));

		expect(result.current.ws).toBeUndefined();
		expect(result.current.loading).toBe(true);
		expect(result.current.error).toBeNull();
	});

	it("resolve 后 slug 匹配 → ws 正确、loading:false、error:null", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{ id: "ws_01", slug: "cgc-academy", name: "CGC 线上学院" },
			{ id: "ws_02", slug: "cgc-shanghai", name: "CGC 上海分社" },
		]);
		const { result } = renderHook(() => useWorkspaceBySlug("cgc-academy"));

		await act(async () => {});
		expect(result.current.ws?.slug).toBe("cgc-academy");
		expect(result.current.loading).toBe(false);
		expect(result.current.error).toBeNull();
	});
	it("PlatformAdmin 非成员：meWorkspaces miss 后按 slug fallback，并标记只读访客", async () => {
		fetchMyWorkspaces.mockResolvedValue([]);
		fetchCurrentProfile.mockResolvedValue({ isPlatformAdmin: true });
		fetchWorkspaceBySlug.mockResolvedValue({
			id: "ws_admin_audit",
			slug: "audit-ws",
			name: "审计工作台",
			joinPolicy: "invite_only",
			sponsorshipEnabled: false,
		});

		const { result } = renderHook(() => useWorkspaceBySlug("audit-ws"));

		await act(async () => {});
		expect(result.current.ws?.name).toBe("审计工作台");
		expect(result.current.ws?.readOnlyVisitor).toBe(true);
		expect(result.current.readOnlyVisitor).toBe(true);
		expect(result.current.loading).toBe(false);
	});

	it("普通用户未知 slug：不 fallback，保持不可访问结果", async () => {
		fetchMyWorkspaces.mockResolvedValue([]);
		fetchCurrentProfile.mockResolvedValue({ isPlatformAdmin: false });

		const { result } = renderHook(() => useWorkspaceBySlug("unknown-ws"));

		await act(async () => {});
		expect(result.current.ws).toBeUndefined();
		expect(result.current.readOnlyVisitor).toBe(false);
		expect(fetchWorkspaceBySlug).not.toHaveBeenCalled();
		expect(result.current.loading).toBe(false);
	});

	it("slug 变化：回到 loading（stale 派生），解析后换到新工作区", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{ id: "ws_01", slug: "cgc-academy", name: "CGC 线上学院" },
			{ id: "ws_02", slug: "cgc-shanghai", name: "CGC 上海分社" },
		]);
		const { result, rerender } = renderHook(
			({ slug }: { slug: string }) => useWorkspaceBySlug(slug),
			{ initialProps: { slug: "cgc-academy" } },
		);
		await act(async () => {});
		expect(result.current.ws?.slug).toBe("cgc-academy");

		rerender({ slug: "cgc-shanghai" });
		// 旧结果视为过期：回到 loading，不渲染旧工作区
		expect(result.current.loading).toBe(true);
		expect(result.current.ws).toBeUndefined();

		await act(async () => {});
		expect(result.current.ws?.slug).toBe("cgc-shanghai");
		expect(result.current.loading).toBe(false);
	});

	it("slug === ''：skip，不发起 fetch，恒 { ws: undefined, loading: false }", async () => {
		const { result } = renderHook(() => useWorkspaceBySlug(""));

		await act(async () => {});
		expect(fetchMyWorkspaces).not.toHaveBeenCalled();
		expect(result.current).toEqual({
			ws: undefined,
			readOnlyVisitor: false,
			loading: false,
			error: null,
			retry: expect.any(Function),
		});
	});

	it("reject → error 非空、loading:false、ws:undefined（不再等同「不存在」）", async () => {
		fetchMyWorkspaces.mockRejectedValue(new Error("network down"));
		const { result } = renderHook(() => useWorkspaceBySlug("cgc-academy"));

		await act(async () => {});
		expect(result.current.ws).toBeUndefined();
		expect(result.current.loading).toBe(false);
		expect(result.current.error).toBeInstanceOf(Error);
		expect(result.current.error?.message).toBe("network down");
	});

	it("retry()：清 error 回 loading 并重新拉取，成功后 error 保持 null", async () => {
		fetchMyWorkspaces.mockRejectedValueOnce(new Error("network down"));
		const { result } = renderHook(() => useWorkspaceBySlug("cgc-academy"));

		await act(async () => {});
		expect(result.current.error?.message).toBe("network down");
		expect(fetchMyWorkspaces).toHaveBeenCalledTimes(1);

		fetchMyWorkspaces.mockResolvedValueOnce([
			{ id: "ws_01", slug: "cgc-academy", name: "CGC 线上学院" },
		]);
		act(() => {
			result.current.retry();
		});
		// retry 立即清 error 并回到 loading（骨架），随后重新拉取
		expect(result.current.error).toBeNull();
		expect(result.current.loading).toBe(true);

		await act(async () => {});
		expect(fetchMyWorkspaces).toHaveBeenCalledTimes(2);
		expect(result.current.ws?.slug).toBe("cgc-academy");
		expect(result.current.error).toBeNull();
		expect(result.current.loading).toBe(false);
	});
});
