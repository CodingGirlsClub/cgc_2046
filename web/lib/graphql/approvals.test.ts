import { describe, it, expect } from "vitest";
import { print } from "graphql";
import { PENDING_APPROVALS_COUNT } from "./approvals";

describe("approvals GraphQL 契约", () => {
	it("PENDING_APPROVALS_COUNT 查询 pendingApprovalsCount", () => {
		expect(print(PENDING_APPROVALS_COUNT)).toContain("query PendingApprovalsCount");
		expect(print(PENDING_APPROVALS_COUNT)).toContain("pendingApprovalsCount");
	});
});
