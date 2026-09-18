import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminFlashbackPage from "./page";

const fetchFlashbackAdminStats = vi.hoisted(() => vi.fn());
const fetchFlashbackAdminRedemptions = vi.hoisted(() => vi.fn());
const updateFlashbackRedemption = vi.hoisted(() => vi.fn());

vi.mock("@/lib/admin", () => ({
	fetchFlashbackAdminStats,
	fetchFlashbackAdminRedemptions,
	updateFlashbackRedemption,
}));

const stats = {
	memory: { delivered: 2, linkOpened: 2, revealed: 1, sentToWall: 1, intentSubmitted: 1 },
	dream: { delivered: 1, linkOpened: 1, revealed: 1, sentToWall: 0, intentSubmitted: 1 },
	overall: { delivered: 3, linkOpened: 3, revealed: 2, sentToWall: 1, intentSubmitted: 2 },
};

const redemptions = [
	{
		id: "r1",
		status: "pending",
		channelNote: "支付宝 138****5678",
		handledNote: null,
		insertedAt: "2026-09-18T10:00:00Z",
		maskedName: "王**",
		city: "北京",
	},
	{
		id: "r2",
		status: "settled",
		channelNote: "微信 wxid_x",
		handledNote: "已打款",
		insertedAt: "2026-09-17T10:00:00Z",
		maskedName: "李**",
		city: "上海",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("/admin/flashback 闪念间看板", () => {
	it("四率矩阵：分线计数 + 率（KTD10 合成事件流口径）", async () => {
		fetchFlashbackAdminStats.mockResolvedValue(stats);
		fetchFlashbackAdminRedemptions.mockResolvedValue([]);

		render(<AdminFlashbackPage />);

		expect(await screen.findByText("记忆线")).toBeInTheDocument();
		const memoryRow = screen.getByText("记忆线").closest("tr");
		expect(memoryRow).not.toBeNull();
		// delivered=2，打开 2（100%）、显影 1（50%）
		expect(memoryRow).toHaveTextContent("2 (100%)");
		expect(memoryRow).toHaveTextContent("1 (50%)");

		const overallRow = screen.getByText("合计").closest("tr");
		expect(overallRow).toHaveTextContent("3");
		expect(overallRow).toHaveTextContent("2 (67%)");
	});

	it("兑换队列：掩码署名/渠道/状态中文标签；终态无流转按钮", async () => {
		fetchFlashbackAdminStats.mockResolvedValue(stats);
		fetchFlashbackAdminRedemptions.mockResolvedValue(redemptions);

		render(<AdminFlashbackPage />);

		expect(await screen.findByText("王**")).toBeInTheDocument();
		const pendingRow = screen.getByText("王**").closest("tr");
		expect(pendingRow).toHaveTextContent("支付宝 138****5678");
		expect(pendingRow).toHaveTextContent("待联系");
		// pending 行三个合法动作可用
		expect(pendingRow).toHaveTextContent("标记已联系");
		expect(screen.queryByText("Invalid Date")).not.toBeInTheDocument();

		const settledRow = screen.getByText("李**").closest("tr");
		expect(settledRow).toHaveTextContent("已兑付");
		// 终态（settled）无操作——「标记已兑付」只出现在非终态行
		const settleButtons = screen.getAllByText("标记已兑付");
		expect(settleButtons).toHaveLength(1);
		expect(settledRow).not.toContain(settleButtons[0]);
	});

	it("状态流转：备注随行提交，成功后刷新列表", async () => {
		fetchFlashbackAdminStats.mockResolvedValue(stats);
		fetchFlashbackAdminRedemptions.mockResolvedValue(redemptions);
		updateFlashbackRedemption.mockResolvedValue({ id: "r1", status: "contacted" });

		render(<AdminFlashbackPage />);
		await screen.findByText("王**");

		fireEvent.change(screen.getByLabelText("处理备注 王**"), {
			target: { value: "已电话联系" },
		});
		fireEvent.click(screen.getByText("标记已联系"));

		await vi.waitFor(() =>
			expect(updateFlashbackRedemption).toHaveBeenCalledWith(
				"r1",
				"contacted",
				"已电话联系",
			),
		);
		// 流转成功后重查两个数据源
		await vi.waitFor(() =>
			expect(fetchFlashbackAdminStats).toHaveBeenCalledTimes(2),
		);
	});

	it("导出 CSV：聚合矩阵表头/数字齐，且零 PII（KTD3）", async () => {
		fetchFlashbackAdminStats.mockResolvedValue(stats);
		// 有兑换数据在场——导出含个人字段的变异才会真红，不靠空数据假绿
		fetchFlashbackAdminRedemptions.mockResolvedValue(redemptions);

		const blobs: Blob[] = [];
		const createdUrls: string[] = [];
		const originalCreate = URL.createObjectURL;
		const originalRevoke = URL.revokeObjectURL;
		const clickSpy = vi
			.spyOn(HTMLAnchorElement.prototype, "click")
			.mockImplementation(() => {});
		URL.createObjectURL = vi.fn((b: Blob) => {
			blobs.push(b);
			const url = `blob:mock-${createdUrls.length}`;
			createdUrls.push(url);
			return url;
		});
		URL.revokeObjectURL = vi.fn();

		try {
			render(<AdminFlashbackPage />);
			fireEvent.click(await screen.findByText("导出 CSV"));

			expect(blobs).toHaveLength(1);
			const csv = await blobs[0].text();

			// 表头（线 × 送达 + 四事件计数与率）
			expect(csv).toContain("分线");
			expect(csv).toContain("送达");
			expect(csv).toContain("链接打开率");
			expect(csv).toContain("意图提交率");
			// 三行分线数字
			expect(csv).toContain("记忆线");
			expect(csv).toContain("圆梦线");
			expect(csv).toContain("合计");
			expect(csv).toContain("100%");

			// KTD3：导出为零 PII——无手机/邮箱/收款渠道/姓名（含掩码名也不进导出）；
			// 断言具体值（渠道原文/掩码名片段/号码片段），注入个人字段的变异必红
			expect(csv).not.toContain("支付宝");
			expect(csv).not.toContain("wxid");
			expect(csv).not.toContain("138");
			expect(csv).not.toContain("王");
			expect(csv).not.toMatch(/phone|email/i);
			expect(clickSpy).toHaveBeenCalled();
		} finally {
			URL.createObjectURL = originalCreate;
			URL.revokeObjectURL = originalRevoke;
			clickSpy.mockRestore();
		}
	});

	it("空库：零值矩阵 + 兑换空态（pilot 前看板可用）", async () => {
		fetchFlashbackAdminStats.mockResolvedValue({
			memory: { delivered: 0, linkOpened: 0, revealed: 0, sentToWall: 0, intentSubmitted: 0 },
			dream: { delivered: 0, linkOpened: 0, revealed: 0, sentToWall: 0, intentSubmitted: 0 },
			overall: { delivered: 0, linkOpened: 0, revealed: 0, sentToWall: 0, intentSubmitted: 0 },
		});
		fetchFlashbackAdminRedemptions.mockResolvedValue([]);

		render(<AdminFlashbackPage />);

		expect(await screen.findByText("记忆线")).toBeInTheDocument();
		const memoryRow = screen.getByText("记忆线").closest("tr");
		// 分母 0 → 率为 —
		expect(memoryRow).toHaveTextContent("—");
		expect(await screen.findByText("暂无兑换申请。")).toBeInTheDocument();
	});

	it("加载失败 → 错误提示，不渲染数据面", async () => {
		fetchFlashbackAdminStats.mockRejectedValue(new Error("boom"));
		fetchFlashbackAdminRedemptions.mockRejectedValue(new Error("boom"));

		render(<AdminFlashbackPage />);

		expect(await screen.findByText("加载失败。")).toBeInTheDocument();
		expect(screen.queryByText("记忆线")).not.toBeInTheDocument();
	});
});
