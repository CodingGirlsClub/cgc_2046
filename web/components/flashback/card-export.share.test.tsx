import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import type { FlashbackCapsuleMe } from "@/lib/graphql/flashback";
import CardExport from "./card-export";

/**
 * 第 4 件：web 分享轻档——navigator.share 存在才显示「分享到…」，
 * 优先分享卡片图文件（canShare 通过），否则降级 url+text；能力缺失只留下载。
 */

const me: FlashbackCapsuleMe = {
	id: "p1",
	fullName: "王若愚",
	surname: "王",
	city: "北京",
	occupationThen: null,
	participation: "attended",
	appliedAt: "2014-01-05T05:06:00.000Z",
	today: { nowStatus: "还在写代码", want: "想骑行", say: null, sentToWallAt: null },
	quote: "我想亲眼看看是不是。",
	answers: [{ id: "m1", questionKey: "self_intro", rawText: "一句当年答案。", text: "一句当年答案。" }],
};

/** jsdom 未实现 canvas.toBlob：桩成直接回一张 PNG blob */
function stubToBlob() {
	HTMLCanvasElement.prototype.toBlob = function toBlob(callback: BlobCallback) {
		callback(new Blob([new Uint8Array([1, 2, 3])], { type: "image/png" }));
	} as HTMLCanvasElement["toBlob"];
}

function stubShare(options: { canShare?: boolean } = {}) {
	const share = vi.fn().mockResolvedValue(undefined);
	Object.defineProperty(navigator, "share", { value: share, configurable: true, writable: true });
	if (options.canShare !== undefined) {
		Object.defineProperty(navigator, "canShare", {
			value: vi.fn().mockReturnValue(options.canShare),
			configurable: true,
			writable: true,
		});
	}
	return share;
}

function clearShare() {
	for (const key of ["share", "canShare"]) {
		// @ts-expect-error 测试清理：删除宿主未实现的分享能力
		delete navigator[key];
	}
}

afterEach(() => {
	cleanup();
	clearShare();
	vi.restoreAllMocks();
});

describe("CardExport · 系统分享（第 4 件）", () => {
	it("无 navigator.share：不渲染「分享到…」，只留下载两钮", () => {
		render(
			<div className="fb-root">
				<CardExport me={me} />
			</div>,
		);
		expect(screen.queryByTestId("fb-export-share")).not.toBeInTheDocument();
		expect(screen.getByRole("button", { name: "保存卡片图片" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "下载 Markdown" })).toBeInTheDocument();
	});

	it("canShare 通过：分享卡片图文件（files 载荷，非 url）", async () => {
		stubToBlob();
		const share = stubShare({ canShare: true });
		render(
			<div className="fb-root">
				<CardExport me={me} />
			</div>,
		);

		fireEvent.click(await screen.findByTestId("fb-export-share"));
		await waitFor(() => expect(share).toHaveBeenCalledTimes(1));
		const payload = share.mock.calls[0][0] as { files?: File[]; url?: string };
		expect(payload.files?.[0]).toBeInstanceOf(File);
		expect(payload.files?.[0].name).toBe("flashback-card.png");
		expect(payload.url).toBeUndefined();
	});

	it("canShare 不可用：降级 url + text（金句与今天的你）", async () => {
		stubToBlob();
		const share = stubShare();
		render(
			<div className="fb-root">
				<CardExport me={me} />
			</div>,
		);

		fireEvent.click(await screen.findByTestId("fb-export-share"));
		await waitFor(() => expect(share).toHaveBeenCalledTimes(1));
		const payload = share.mock.calls[0][0] as { files?: File[]; url?: string; text?: string };
		expect(payload.files).toBeUndefined();
		expect(payload.url).toBe(window.location.href);
		expect(payload.text).toContain("我想亲眼看看是不是。");
	});

	it("用户取消（AbortError）：静默不抛", async () => {
		stubToBlob();
		const share = vi.fn().mockRejectedValue(new DOMException("cancel", "AbortError"));
		Object.defineProperty(navigator, "share", { value: share, configurable: true, writable: true });
		render(
			<div className="fb-root">
				<CardExport me={me} />
			</div>,
		);

		fireEvent.click(await screen.findByTestId("fb-export-share"));
		await waitFor(() => expect(share).toHaveBeenCalled());
		expect(screen.getByTestId("fb-export-share")).toBeInTheDocument();
	});
});
