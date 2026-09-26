import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import { WishFrames } from "./wish-frames";
import { FLASHBACK_ENDORSE_WISH, type FlashbackWish } from "@/lib/graphql/flashback";

/**
 * H3 止血：长廊「我能出力」不再对无链接通道的用户调接口报
 * 答非所问的错——无 token 点击出小程序指引；持 token 仍走原附议。
 */

const endorseRunner = vi.fn();

vi.mock("@apollo/client/react", async (importOriginal) => {
	const mod = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...mod,
		useMutation: (doc: unknown) => {
			if (doc === FLASHBACK_ENDORSE_WISH) return [endorseRunner, { loading: false }];
			return [vi.fn().mockResolvedValue({ data: {} }), { loading: false }];
		},
	};
});

const wish: FlashbackWish = {
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

beforeEach(() => {
	endorseRunner.mockReset();
	endorseRunner.mockResolvedValue({ data: { flashbackEndorseWish: { endorsementCount: 3 } } });
});

afterEach(cleanup);

describe("长廊我能出力（H3）", () => {
	it("无 token：出小程序指引，不发附议请求", () => {
		render(
			<WishFrames publicWishes={[wish]} myPrivateWishes={[]} myWishQuotaRemaining={null} token={null} onChanged={() => {}} />,
		);
		fireEvent.click(screen.getByRole("button", { name: "我能出力" }));
		const guide = screen.getByTestId("fb-wish-guide");
		expect(guide).toHaveTextContent("程序媛汇");
		expect(endorseRunner).not.toHaveBeenCalled();
	});

	it("持 token：仍直接附议", () => {
		render(
			<WishFrames publicWishes={[wish]} myPrivateWishes={[]} myWishQuotaRemaining={null} token="tok" onChanged={() => {}} />,
		);
		fireEvent.click(screen.getByRole("button", { name: "我能出力" }));
		expect(endorseRunner).toHaveBeenCalledWith({ variables: { token: "tok", wishId: "w-1" } });
	});
});
