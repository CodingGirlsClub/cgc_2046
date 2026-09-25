import { describe, it, expect, vi } from "vitest";
import { screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import { WishEchoCard } from "./wish-echo-card";
import type { FlashbackPublicWishEcho } from "@/lib/graphql/flashback";

const echoPublished: FlashbackPublicWishEcho = {
	id: "e-1",
	content: "第一季定档北京",
	status: "published",
	publishedAt: "2026-09-20T08:00:00Z",
	correctedAt: null,
};

const echoCorrected: FlashbackPublicWishEcho = {
	id: "e-2",
	content: "第一季改到上海\n圆",
	status: "corrected",
	publishedAt: "2026-09-21T10:00:00Z",
	correctedAt: "2026-09-22T09:00:00Z",
};

const echoLatest: FlashbackPublicWishEcho = {
	id: "e-3",
	content: "另一条已发布回响",
	status: "published",
	publishedAt: "2026-09-23T12:00:00Z",
	correctedAt: null,
};

describe("WishEchoCard(#836 回响卡)", () => {
	it("显示主办方署名、发布时间;正文按 pre-wrap 渲染;不显示已更正徽章(status=published)", () => {
		render(
			<WishEchoCard
				latest={echoPublished}
				echoes={[echoPublished]}
				expanded={false}
				onToggleExpanded={() => {}}
			/>,
		);
		// aria-label on section
		const region = screen.getByTestId("fb-wish-echo-card");
		expect(region.getAttribute("aria-label")).toMatch(/回响|Echo/);
		// byline
		expect(screen.getByText("主办方")).toBeInTheDocument();
		// published time present
		expect(region.querySelector("time")).toBeTruthy();
		// no corrected badge
		expect(screen.queryByTestId("fb-wish-echo-corrected")).toBeNull();
		// body with pre-wrap style class
		const body = screen.getByTestId("fb-wish-echo-body");
		expect(body.textContent).toBe("第一季定档北京");
		// not expanded → no toggle for single echo
		expect(screen.queryByTestId("fb-wish-echo-toggle")).toBeNull();
	});

	it("corrected 状态显示「已更正」徽章", () => {
		render(
			<WishEchoCard
				latest={echoCorrected}
				echoes={[echoCorrected]}
				expanded={false}
				onToggleExpanded={() => {}}
			/>,
		);
		expect(screen.getByTestId("fb-wish-echo-corrected")).toBeInTheDocument();
		expect(screen.getByText("已更正")).toBeInTheDocument();
	});

	it("多条回响:默认不展开,只显示最新一条;点「全部 N 条回响」显示按时间正序的全部;再点收起只留最新", () => {
		const echoes = [echoCorrected, echoLatest]; // 时间正序(corrected < latest)
		const onToggle = vi.fn();
		const { rerender } = render(
			<WishEchoCard
				latest={echoLatest}
				echoes={echoes}
				expanded={false}
				onToggleExpanded={onToggle}
			/>,
		);
		// 默认:只有最新一条
		expect(screen.getAllByTestId("fb-wish-echo")).toHaveLength(1);
		// toggle label 含 N
		const toggle = screen.getByTestId("fb-wish-echo-toggle");
		expect(toggle).toHaveTextContent("全部 2 条回响");
		expect(toggle.getAttribute("aria-expanded")).toBe("false");

		// 展开
		fireEvent.click(toggle);
		expect(onToggle).toHaveBeenCalledTimes(1);
		rerender(
			<WishEchoCard
				latest={echoLatest}
				echoes={echoes}
				expanded={true}
				onToggleExpanded={onToggle}
			/>,
		);
		const items = screen.getAllByTestId("fb-wish-echo");
		expect(items).toHaveLength(2);
		// 时间正序:e-2(corrected)在前,e-3(latest)在后
		expect(items[0].textContent).toContain("第一季改到上海");
		expect(items[1].textContent).toContain("另一条已发布回响");
		// 展开态 toggle 显示「收起回响」
		const close = screen.getByTestId("fb-wish-echo-toggle");
		expect(close).toHaveTextContent("收起回响");
		expect(close.getAttribute("aria-expanded")).toBe("true");
		// corrected 徽章依然在列
		expect(screen.getAllByTestId("fb-wish-echo-corrected")).toHaveLength(1);
	});

	it("en 渲染:署名/徽章/toggle/region 都是英文", () => {
		render(
			<WishEchoCard
				latest={echoCorrected}
				echoes={[echoCorrected, echoLatest]}
				expanded={false}
				onToggleExpanded={() => {}}
			/>,
			{ locale: "en" },
		);
		expect(screen.getByText("Organizers")).toBeInTheDocument();
		expect(screen.getByText("Corrected")).toBeInTheDocument();
		expect(screen.getByTestId("fb-wish-echo-card").getAttribute("aria-label")).toBe("Echo");
		expect(screen.getByTestId("fb-wish-echo-toggle")).toHaveTextContent("All 2 echoes");
	});
});
