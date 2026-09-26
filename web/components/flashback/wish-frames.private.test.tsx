import { describe, it, expect, vi } from "vitest";
import { screen, fireEvent } from "@testing-library/react";
import { Kind, type DocumentNode, type SelectionSetNode } from "graphql";
import { render } from "@/test-utils";
import { WishFrames } from "./wish-frames";
import { FLASHBACK_CAPSULE, type FlashbackWish } from "@/lib/graphql/flashback";

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

/**
 * 查询里某个字段实际选取的子字段（展开同文档内的 fragment）。测试数据按它裁剪成真实返回的形状——
 * 手写数据自带 comments / mine，曾掩盖胶囊查询漏取私密愿望字段导致的弹窗崩溃（梳理文档 H0）。
 */
function selectedFields(doc: DocumentNode, fieldName: string): string[] {
	const fragments = new Map<string, SelectionSetNode>();
	for (const definition of doc.definitions) {
		if (definition.kind === Kind.FRAGMENT_DEFINITION) fragments.set(definition.name.value, definition.selectionSet);
	}
	const expand = (set: SelectionSetNode): string[] =>
		set.selections.flatMap((selection) => {
			if (selection.kind === Kind.FIELD) return [selection.name.value];
			if (selection.kind === Kind.FRAGMENT_SPREAD) return expand(fragments.get(selection.name.value)!);
			return [];
		});
	const find = (set: SelectionSetNode | undefined): SelectionSetNode | undefined => {
		for (const selection of set?.selections ?? []) {
			if (selection.kind === Kind.FIELD && selection.name.value === fieldName) return selection.selectionSet;
			const nested =
				selection.kind === Kind.FRAGMENT_SPREAD ? fragments.get(selection.name.value) : "selectionSet" in selection ? selection.selectionSet : undefined;
			const found = find(nested);
			if (found) return found;
		}
		return undefined;
	};
	const operation = doc.definitions.find((definition) => definition.kind === Kind.OPERATION_DEFINITION);
	const selection = find(operation && "selectionSet" in operation ? operation.selectionSet : undefined);
	if (!selection) throw new Error(`${fieldName} not selected`);
	return expand(selection);
}

const privateWish: FlashbackWish = {
	id: "w-private",
	content: "只给自己看的愿望",
	city: null,
	wisherMasked: null,
	endorsementCount: 0,
	endorsedByMe: false,
	mine: true,
	comments: [],
	latestEcho: null,
	echoCount: 0,
	echoes: [],
	insertedAt: "2026-09-20T08:00:00Z",
};

describe("WishFrames · 私密愿望（胶囊查询真实形状）", () => {
	it("点开私密愿望不崩溃，本人能看到删除入口", () => {
		const fetched = Object.fromEntries(
			selectedFields(FLASHBACK_CAPSULE, "myPrivateWishes").map((key) => [key, privateWish[key as keyof FlashbackWish]]),
		) as unknown as FlashbackWish;

		render(
			<WishFrames publicWishes={[]} myPrivateWishes={[fetched]} myWishQuotaRemaining={3} token={null} onChanged={() => {}} />,
		);
		fireEvent.click(screen.getByText("只给自己看的愿望"));

		expect(screen.getByRole("button", { name: "删除" })).toBeInTheDocument();
	});
});
