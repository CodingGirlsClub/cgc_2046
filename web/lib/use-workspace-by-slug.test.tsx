import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook, act } from "@testing-library/react";
import { useWorkspaceBySlug } from "./use-workspace-by-slug";

/**
 * useWorkspaceBySlug（#017 Bug B：网络失败 ≠ 无权限）单测。
 *
 * 本 hook 只消费 fetchMyWorkspaces 真实数据；#017 之前 .catch 把一切失败
 * 等同「slug 不在我的列表」（误报「工作区不可访问」），现在保留 error 通道 +
 * retry 出口。测试覆盖：首帧 loading、匹配/不匹配、slug 变化 stale、
 * 空 slug skip、reject → error、retry 重拉并清 error。
 */

const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

beforeEach(() => {
	fetchMyWorkspaces.mockReset();
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
