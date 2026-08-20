import { describe, it, expect, vi, beforeEach } from "vitest";
import { act, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import WechatQrPanel from "./wechat-qr-panel";

// vi.mock 工厂会被提升（hoist），mock 函数必须用 vi.hoisted 定义
const { startMock } = vi.hoisted(() => ({
	startMock: vi.fn(),
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...actual,
		useMutation: (doc: unknown) => {
			const name = (
				doc as { definitions?: Array<{ name?: { value?: string } }> }
			)?.definitions?.[0]?.name?.value;
			if (name === "WechatLoginStart") return [startMock, { loading: false }];
			return [vi.fn(), { loading: false }];
		},
	};
});

function mockStartResult(overrides: Record<string, unknown> = {}) {
	return {
		data: {
			wechatLoginStart: {
				qrUrl: "https://open.weixin.qq.com/connect/qrconnect?appid=wx&state=s1",
				state: "s1",
				expiresInSeconds: 600,
				...overrides,
			},
		},
	};
}

describe("WechatQrPanel（plan U5.8 / advisor02 M1+M6+M7）", () => {
	beforeEach(() => {
		startMock.mockReset();
	});

	it("挂载即 wechatLoginStart，成功后 iframe 渲染微信 qrconnect URL（D2：微信自渲染）", async () => {
		startMock.mockResolvedValue(mockStartResult());

		render(<WechatQrPanel />);

		await waitFor(() => {
			const frame = screen.getByTitle("微信登录二维码");
			expect(frame).toBeInTheDocument();
			// iframe src = 后端返回的 qrUrl，不是本地生成
			expect(frame.getAttribute("src")).toMatch(
				/open\.weixin\.qq\.com\/connect\/qrconnect/,
			);
		});
		// next 透传：当前页面 ?next= 带入 mutation 变量
		expect(startMock).toHaveBeenCalledWith(
			expect.objectContaining({ variables: { next: null } }),
		);
		expect(screen.getByText("打开微信扫一扫，扫码登录")).toBeInTheDocument();
	});

	it("unavailable（凭证未配置）：降级提示，不渲染 iframe/扫码卡（M7）", async () => {
		startMock.mockResolvedValue({ data: { wechatLoginStart: null } });

		render(<WechatQrPanel />);

		await waitFor(() => {
			expect(
				screen.getByText("微信扫码登录暂未开放，请使用其他方式登录"),
			).toBeInTheDocument();
		});
		expect(screen.queryByTitle("微信登录二维码")).not.toBeInTheDocument();
	});

	it("请求异常（wechat_login_unavailable code）：同样降级提示", async () => {
		startMock.mockRejectedValue({
			errors: [{ extensions: { code: "wechat_login_unavailable" } }],
		});

		render(<WechatQrPanel />);

		await waitFor(() => {
			expect(
				screen.getByText("微信扫码登录暂未开放，请使用其他方式登录"),
			).toBeInTheDocument();
		});
	});

	it("expiresInSeconds 到期：显示刷新按钮，点击重新出码（M7）", async () => {
		vi.useFakeTimers();
		try {
			startMock.mockResolvedValue(mockStartResult({ expiresInSeconds: 1 }));

			render(<WechatQrPanel />);

			// mutation resolve 是微任务，fake timer 不阻塞——flush 即可
			await act(async () => {
				await Promise.resolve();
			});
			expect(screen.getByTitle("微信登录二维码")).toBeInTheDocument();

			act(() => {
				vi.advanceTimersByTime(1500);
			});

			expect(screen.getByText("二维码已过期")).toBeInTheDocument();
			expect(screen.getByRole("button", { name: "刷新二维码" })).toBeInTheDocument();

			startMock.mockResolvedValue(
				mockStartResult({ state: "s2", expiresInSeconds: 600 }),
			);
			fireEvent.click(screen.getByRole("button", { name: "刷新二维码" }));

			// mutation resolve 是微任务，fake timer 不阻塞——flush 即可
			await act(async () => {
				await Promise.resolve();
			});
			expect(screen.getByTitle("微信登录二维码")).toBeInTheDocument();
			expect(startMock).toHaveBeenCalledTimes(2);
		} finally {
			vi.useRealTimers();
		}
	});
});

