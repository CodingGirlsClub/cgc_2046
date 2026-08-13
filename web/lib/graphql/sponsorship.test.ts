import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
	LIST_EVENT_SPONSORSHIPS,
	LIST_WORKSPACE_SPONSORSHIPS,
	CREATE_SPONSORSHIP,
	APPROVE_SPONSORSHIP,
	REJECT_SPONSORSHIP,
	FULFILL_DELIVERY,
} from "./sponsorship";
import { parseSponsorshipTiers } from "../public-offerings";

describe("sponsorship GraphQL 契约（对齐 sponsorship.ex/sponsorship_delivery.ex graphql 段 + schema.graphql）", () => {
	it("赞助列表：按目标 filter（eventId / workspaceId）+ deliveries 履约账本嵌套", () => {
		const doc = print(LIST_EVENT_SPONSORSHIPS);
		// workspaceId 参与 filter：read policy 经 filter 提取租户（同 E-11 列表模式）
		expect(doc).toContain(
			"filter: { eventId: { eq: $eventId }, workspaceId: { eq: $workspaceId } }",
		);
		expect(doc).toContain("deliveries {");
		expect(doc).toContain("fulfilledAt");
		expect(doc).toContain("proofNote");
		expect(doc).toContain("exclusive");

		expect(print(LIST_WORKSPACE_SPONSORSHIPS)).toContain(
			"sponsorships(filter: { workspaceId: { eq: $workspaceId } })",
		);
	});

	it("mutation 形状：create 走 input；approve 仅 id；reject/fulfill 带 input 附加参数", () => {
		expect(print(CREATE_SPONSORSHIP)).toContain(
			"mutation CreateSponsorship($input: CreateSponsorshipInput!)",
		);
		expect(print(APPROVE_SPONSORSHIP)).toContain("approveSponsorship(id: $id)");
		expect(print(REJECT_SPONSORSHIP)).toContain(
			"rejectSponsorship(id: $id, input: $input)",
		);
		expect(print(FULFILL_DELIVERY)).toContain(
			"fulfillDelivery(id: $id, input: $input)",
		);
	});
});

describe("parseSponsorshipTiers（JsonString 数组 → 档位配置）", () => {
	it("合法项解析为 SponsorshipTierConfig；非法项/非法 JSON 静默丢弃", () => {
		const raw = [
			JSON.stringify({
				id: "t-1",
				name: "冠名",
				amount_suggestion: 10_000,
				benefits: ["logo 展示位", "鸣谢页"],
				exclusive: true,
			}),
			"not-json",
			JSON.stringify({ name: "缺 id" }),
		];

		const tiers = parseSponsorshipTiers(raw);
		expect(tiers).toHaveLength(1);
		expect(tiers[0]).toEqual({
			id: "t-1",
			name: "冠名",
			amountSuggestion: 10_000,
			benefits: ["logo 展示位", "鸣谢页"],
			exclusive: true,
		});
	});

	it("null/非数组兜底空列表", () => {
		expect(parseSponsorshipTiers(null)).toEqual([]);
		expect(parseSponsorshipTiers(undefined)).toEqual([]);
	});
});
