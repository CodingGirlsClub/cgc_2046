import { describe, it, expect, vi } from "vitest";
import { screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import { WishFrames } from "./wish-frames";
import type { FlashbackWish } from "@/lib/graphql/flashback";

vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: vi.fn().mockResolvedValue({ data: {} }),
		mutate: vi.fn().mockResolvedValue({ data: {} }),
	},
}));
vi.mock("@apollo/client/react", async (importOriginal) => {
	const mod = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...mod,
		useMutation: () => [vi.fn().mockResolvedValue({ data: {} })],
	};
});

const baseWish: FlashbackWish = {
	id: "w-1",
	content: "想再回到 2014 年的北京",
	city: "北京",
	wisherMasked: "王**",
	endorsementCount: 2,
	endorsedByMe: false,
	mine: false,
	comments: [],
	latestEcho: null,
	echoCount: 0,
	echoes: [],
	insertedAt: "2026-09-20T08:00:00Z",
};

const echoPublished = {
	id: "e-1",
	content: "第一季定档北京",
	status: "published" as const,
	publishedAt: "2026-09-20T08:00:00Z",
	correctedAt: null,
};
const echoCorrected = {
	id: "e-2",
	content: "第二季改到上海",
	status: "corrected" as const,
	publishedAt: "2026-09-21T10:00:00Z",
	correctedAt: "2026-09-22T09:00:00Z",
};

const wishWithEchoes: FlashbackWish = {
	...baseWish,
	id: "w-echo",
	latestEcho: echoCorrected,
	echoCount: 2,
	echoes: [echoPublished, echoCorrected],
};

describe("WishFrames · 成员面长廊回响卡(#836)", () => {
	it("无回响的 wish 不渲染任何回响区块", () => {
		render(
			<WishFrames
				publicWishes={[baseWish]}
				myPrivateWishes={[]}
				myWishQuotaRemaining={3}
				token={null}
				onChanged={() => {}}
			/>,
		);
		// open the wish modal to inspect detail
		fireEvent.click(screen.getByText("想再回到 2014 年的北京"));
		// no echo region
		expect(screen.queryByTestId("fb-wish-echo-card")).toBeNull();
	});

	it("有回响的 wish 在 modal 中显示回响卡:署名主办方、最新一条、corrected 徽章、N 条展开按钮", () => {
		render(
			<WishFrames
				publicWishes={[wishWithEchoes]}
				myPrivateWishes={[]}
				myWishQuotaRemaining={3}
				token={null}
				onChanged={() => {}}
			/>,
		);
		fireEvent.click(screen.getByText("想再回到 2014 年的北京"));
		const card = screen.getByTestId("fb-wish-echo-card");
		expect(card).toBeInTheDocument();
		expect(card.getAttribute("aria-label")).toBe("回响");
		expect(screen.getByText("主办方")).toBeInTheDocument();
		// corrected badge shown (latest=corrected)
		expect(screen.getByTestId("fb-wish-echo-corrected")).toBeInTheDocument();
		// toggle for 2 echoes
		expect(screen.getByTestId("fb-wish-echo-toggle")).toHaveTextContent("全部 2 条回响");
	});

	it("点「全部 N 条回响」展开后,按时间正序展示全部回响,带各自的 corrected/published 徽标", () => {
		render(
			<WishFrames
				publicWishes={[wishWithEchoes]}
				myPrivateWishes={[]}
				myWishQuotaRemaining={3}
				token={null}
				onChanged={() => {}}
			/>,
		);
		fireEvent.click(screen.getByText("想再回到 2014 年的北京"));
		fireEvent.click(screen.getByTestId("fb-wish-echo-toggle"));
		const items = screen.getAllByTestId("fb-wish-echo");
		expect(items).toHaveLength(2);
		expect(items[0].textContent).toContain("第一季定档北京");
		expect(items[1].textContent).toContain("第二季改到上海");
		// 第二条是 corrected,有 badge
		expect(screen.getAllByTestId("fb-wish-echo-corrected")).toHaveLength(1);
	});
});
