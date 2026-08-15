import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import PublicOfferingsPage from "./public-offerings";

const fetchPublicOfferings = vi.hoisted(() => vi.fn());

vi.mock("@/lib/public-offerings", () => ({
	fetchPublicOfferings,
}));

const rows = [
	{
		id: "evt1",
		slug: "campus-hack",
		title: "Campus Hack",
		status: "open",
		visibility: "public",
		enrollmentPolicy: "open",
		registrationDeadline: "2026-09-01T00:00:00Z",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("/events 公开发现页（E-5 #50 G4）", () => {
	it("公开条目渲染为卡片（title + 状态 + 策略）", async () => {
		fetchPublicOfferings.mockResolvedValue(rows);

		render(<PublicOfferingsPage kind="event" />);

		expect(await screen.findByText("Campus Hack")).toBeInTheDocument();
		// 卡片副行：报名策略中文 + 截止
		expect(screen.getByText(/直接报名/)).toBeInTheDocument();
		// 公开发现页不要求登录（游客可浏览）
		expect(screen.getByRole("heading", { name: "公开活动" })).toBeInTheDocument();
	});

	it("空列表 → 空态文案", async () => {
		fetchPublicOfferings.mockResolvedValue([]);

		render(<PublicOfferingsPage kind="course" />);

		expect(await screen.findByText("暂无公开课程。")).toBeInTheDocument();
	});

	it("加载失败 → 错误态（不静默）", async () => {
		fetchPublicOfferings.mockRejectedValue(new Error("network"));

		render(<PublicOfferingsPage kind="event" />);

		expect(await screen.findByRole("alert")).toHaveTextContent("加载失败");
	});
});
