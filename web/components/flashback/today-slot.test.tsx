import { describe, it, expect, vi, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import TodaySlot from "./today-slot";
import type { FlashbackCapsuleMe } from "@/lib/graphql/flashback";

/**
 * 「去寄出它」引导的可达性契约（视觉审计 2026-09 D2）：
 *
 * 找回绑定后 token 一律作废是设计常态——今天格未寄出位的「去寄出它」裸链
 * /flashback/enter 会把已绑定用户带到假失效页（enter 只认 token）。修复为按
 * token 在手与否分流：有 token 仍走 enter 旅程；无 token 落 hub 自助找回区
 * 并明示「找回后可寄出」，不再误导用户踩失效。
 */

vi.mock("next/navigation", () => ({
	usePathname: () => "/flashback/capsule",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	useParams: () => ({}),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

vi.mock("@/lib/apollo-client", () => ({
	client: { mutate: vi.fn() },
}));

const meUnsent: FlashbackCapsuleMe = {
	id: "me-1",
	fullName: "李雯",
	surname: "李",
	city: "杭州",
	occupationThen: "美术老师",
	participation: "attended",
	appliedAt: "2017-09-26T15:55:00Z",
	today: null,
	quote: null,
	answers: [],
};

function renderSlot(token: string | null) {
	return render(<TodaySlot me={meUnsent} token={token} />);
}

afterEach(() => {
	cleanup();
});

describe("TodaySlot 未寄出引导（D2 分流）", () => {
	it("token 在手：链接走 enter 旅程，不出找回提示", () => {
		renderSlot("tok-123");
		expect(
			screen.getByRole("link", { name: "去寄出它 →" }),
		).toHaveAttribute("href", "/flashback/enter");
		expect(screen.queryByText("找回你的档案链接后可寄出")).not.toBeInTheDocument();
	});

	it("无 token（已绑定被作废是常态）：链到 hub 自助找回区并明示找回后可寄出", () => {
		renderSlot(null);
		expect(
			screen.getByRole("link", { name: "去寄出它 →" }),
		).toHaveAttribute("href", "/flashback");
		expect(screen.getByText("找回你的档案链接后可寄出")).toBeInTheDocument();
	});
});
