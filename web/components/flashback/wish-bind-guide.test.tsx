import { describe, it, expect, vi, afterEach, beforeEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import { WishFormModal } from "./wish-frames";
import { FLASHBACK_CREATE_WISH } from "@/lib/graphql/flashback";

/**
 * 绑定引导可达成契约（视觉审计 2026-09 D7）：
 *
 * 登录但未绑定档案的用户写愿望被拒（createWish.person_not_bound）时，
 * 错误文案旁的「去绑定闪念间档案」原来链到 /flashback/enter ——无 token
 * 状态下必落假失效页（与 today-slot 同款假失效 pattern，端到端唯一通
 * 是小程序）。修复为链到 hub 自助找回区并带 #recover 锚，点直达找回表单。
 */

const { mutateMock } = vi.hoisted(() => ({ mutateMock: vi.fn() }));

vi.mock("@/lib/apollo-client", () => ({
	client: {
		mutate: (opts: unknown) => mutateMock(opts),
		query: () => Promise.resolve({ data: { flashbackCities: [] } }),
	},
}));

vi.mock("next/navigation", () => ({
	usePathname: () => "/flashback/wishes",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	useParams: () => ({}),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

vi.mock("@apollo/client/react", () => ({
	useMutation: (doc: unknown) => [
		(opts: { variables?: unknown }) => mutateMock({ mutation: doc, variables: opts?.variables }),
		{ loading: false },
	],
}));

beforeEach(() => {
	mutateMock.mockReset();
	mutateMock.mockImplementation((opts) => {
		const doc = (opts as { mutation?: unknown }).mutation;
		if (doc === FLASHBACK_CREATE_WISH) {
			return Promise.reject({
				graphQLErrors: [
					{
						message: "person not bound",
						extensions: { code: "flashback_person_not_bound" },
					},
				],
			});
		}
		return Promise.resolve({ data: {} });
	});
});

afterEach(() => {
	cleanup();
});

function renderModal() {
	return render(
		<WishFormModal
			token="tok-demo"
			busy={false}
			myWishQuotaRemaining={3}
			onClose={() => {}}
			onDone={() => {}}
		/>,
	);
}

describe("WishFormModal 档案未绑定引导（D7）", () => {
	it("person_not_bound 被拒时，绑定引导链到 hub 找回区（带 #recover 锚），不是 enter 假失效页", async () => {
		renderModal();
		const textarea = document.querySelector("textarea");
		expect(textarea).not.toBeNull();
		fireEvent.change(textarea!, { target: { value: "十年后，我想在上海带十位女生写出第一行代码" } });
		fireEvent.click(screen.getByRole("button", { name: "许下这个愿" }));

		await waitFor(() => {
			expect(screen.getByRole("link", { name: "去绑定闪念间档案" })).toBeInTheDocument();
		});
		expect(
			screen.getByRole("link", { name: "去绑定闪念间档案" }),
		).toHaveAttribute("href", "/flashback#recover");
	});
});
