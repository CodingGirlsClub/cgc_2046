import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import ProfileView from "./profile-view";
import { FLASHBACK_PUBLIC_PROFILE } from "@/lib/graphql/flashback";

/**
 * 实名档案页（L5 前只有混态 404）：钉住「网络失败可重试」与
 * 「服务端确认未授权/不存在 → 404」两条路径不再混为一个 404。
 */

const queryMock = vi.fn();

vi.mock("@/lib/apollo-client", () => ({
	client: { query: (opts: unknown) => queryMock(opts) },
}));

const profile = {
	flashbackPublicProfile: {
		fullName: "王晓雨",
		year: 2014,
		city: "北京",
		eventName: "Rails Girls 北京",
		quote: "我想成为一个敢说「我不会，但我可以学」的人。",
		creditedNote: null,
		publicSlug: "wang-xiaoyu",
	},
};

beforeEach(() => {
	queryMock.mockReset();
});

afterEach(cleanup);

describe("实名档案页错误分支（L5）", () => {
	it("网络失败：错误提示 + 重试，不再冒充 404", async () => {
		queryMock.mockRejectedValue(new Error("network"));
		render(<ProfileView slug="wang-xiaoyu" />);
		expect(await screen.findByRole("alert")).toHaveTextContent("页面加载失败");
		expect(screen.queryByText(/不存在或未公开/)).not.toBeInTheDocument();
	});

	it("点重试重新拉取，成功渲染档案", async () => {
		queryMock.mockRejectedValueOnce(new Error("network"));
		queryMock.mockResolvedValueOnce({ data: profile });
		render(<ProfileView slug="wang-xiaoyu" />);
		await screen.findByRole("alert");
		fireEvent.click(screen.getByTestId("fb-profile-retry"));
		expect(await screen.findByRole("heading", { name: "王晓雨" })).toBeInTheDocument();
		expect(queryMock).toHaveBeenCalledTimes(2);
	});

	it("服务端确认不存在/未授权：仍是 404 态（无重试按钮）", async () => {
		queryMock.mockResolvedValue({ data: { flashbackPublicProfile: null } });
		render(<ProfileView slug="someone-else" />);
		expect(await screen.findByText("这个链接对应的实名档案不存在，或尚未授权公开。")).toBeInTheDocument();
		expect(screen.queryByTestId("fb-profile-retry")).not.toBeInTheDocument();
	});
});
