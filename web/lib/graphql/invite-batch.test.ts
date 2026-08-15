import { describe, expect, it } from "vitest";
import { print } from "graphql";
import {
	CREATE_INVITE_BATCH,
	DISABLE_INVITE_BATCH,
	LIST_INVITE_BATCHES,
} from "./invite-batch";

describe("InviteBatch GraphQL 契约（对齐 schema.graphql）", () => {
	it("LIST：workspaceId + offering filter、50 条 keyset 分页和 endKeyset", () => {
		const doc = print(LIST_INVITE_BATCHES);

		expect(doc).toContain(
			"query ListInviteBatches($filter: InviteBatchFilterInput, $first: Int!, $after: String)",
		);
		expect(doc).toContain("inviteBatches(filter: $filter, first: $first, after: $after)");
		expect(doc).toContain("endKeyset");
		for (const field of [
			"id",
			"workspaceId",
			"eventId",
			"courseId",
			"inviteCode",
			"quota",
			"remainingQuota",
			"expiresAt",
			"status",
			"remark",
			"insertedAt",
		]) {
			expect(doc).toContain(field);
		}
	});

	it("CREATE：CreateInviteBatchInput 与完整结果字段", () => {
		const doc = print(CREATE_INVITE_BATCH);

		expect(doc).toContain("mutation CreateInviteBatch($input: CreateInviteBatchInput!)");
		expect(doc).toContain("createInviteBatch(input: $input)");
		expect(doc).toContain("errors {");
		expect(doc).toContain("message");
	});

	it("DISABLE：按 id 更新并返回 result/errors", () => {
		const doc = print(DISABLE_INVITE_BATCH);

		expect(doc).toContain("mutation DisableInviteBatch($id: ID!)");
		expect(doc).toContain("disableInviteBatch(id: $id)");
		expect(doc).toContain("result {");
		expect(doc).toContain("status");
		expect(doc).toContain("errors {");
	});
});
