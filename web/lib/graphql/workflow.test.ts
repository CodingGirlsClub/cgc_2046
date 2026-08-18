import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
	GET_WORKFLOW_RUN,
	LIST_WORKFLOW_RUNS,
	WORKFLOW_RUN_STATUS_LABEL,
} from "./workflow";

describe("#40 workflow GraphQL 契约（对齐 schema.graphql 实测）", () => {
	it("LIST_WORKFLOW_RUNS：filter eq 包装 + 分页参数 + count/results + 游标 + 全字段", () => {
		const doc = print(LIST_WORKFLOW_RUNS);
		expect(doc).toContain(
			"query ListWorkflowRuns($filter: WorkflowRunFilterInput!, $first: Int, $after: String)",
		);
		expect(doc).toContain(
			"listWorkflowRuns(filter: $filter, first: $first, after: $after)",
		);
		expect(doc).toContain("count");
		expect(doc).toContain("results {");
		expect(doc).toContain("id");
		expect(doc).toContain("workspaceId");
		expect(doc).toContain("definitionId");
		expect(doc).toContain("definitionVersion");
		expect(doc).toContain("status");
		expect(doc).toContain("inputSnapshot");
		expect(doc).toContain("facts");
		expect(doc).toContain("partitionId");
		expect(doc).toContain("version");
		expect(doc).toContain("startedAt");
		expect(doc).toContain("finishedAt");
		expect(doc).toContain("definition {");
		expect(doc).toContain("type");
		expect(doc).toContain("steps");
		expect(doc).toContain("startKeyset");
		expect(doc).toContain("endKeyset");
	});

	it("GET_WORKFLOW_RUN：id 参数 + 详情字段", () => {
		const doc = print(GET_WORKFLOW_RUN);
		expect(doc).toContain("query GetWorkflowRun($id: ID!)");
		expect(doc).toContain("getWorkflowRun(id: $id)");
		expect(doc).toContain("status");
		expect(doc).toContain("facts");
		expect(doc).toContain("definition {");
		expect(doc).toContain("steps");
	});

	it("WORKFLOW_RUN_STATUS_LABEL：七态 key 名齐全", () => {
		expect(WORKFLOW_RUN_STATUS_LABEL.pending).toBe("labels.workflowStatus.pending");
		expect(WORKFLOW_RUN_STATUS_LABEL.running).toBe("labels.workflowStatus.running");
		expect(WORKFLOW_RUN_STATUS_LABEL.waiting).toBe("labels.workflowStatus.waiting");
		expect(WORKFLOW_RUN_STATUS_LABEL.succeeded).toBe("labels.workflowStatus.succeeded");
		expect(WORKFLOW_RUN_STATUS_LABEL.failed).toBe("labels.workflowStatus.failed");
		expect(WORKFLOW_RUN_STATUS_LABEL.cancelled).toBe("labels.workflowStatus.cancelled");
		expect(WORKFLOW_RUN_STATUS_LABEL.expired).toBe("labels.workflowStatus.expired");
	});
});
