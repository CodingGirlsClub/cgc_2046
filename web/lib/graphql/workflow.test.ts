import { describe, expect, it } from "vitest";
import { print } from "graphql";
import { PLATFORM_WORKFLOW_AUDIT, WORKFLOW_RUN_STATUS_LABEL } from "./workflow";

describe("redacted workflow audit GraphQL contract", () => {
  it("does not request facts or input snapshots", () => {
    const doc = print(PLATFORM_WORKFLOW_AUDIT);
    expect(doc).toContain("platformWorkflowAudit");
    expect(doc).toContain("definitionType");
    expect(doc).toContain("startedAt");
    expect(doc).not.toContain("facts");
    expect(doc).not.toContain("inputSnapshot");
  });

  it("keeps status labels", () => {
    expect(WORKFLOW_RUN_STATUS_LABEL.pending).toBe("labels.workflowStatus.pending");
    expect(WORKFLOW_RUN_STATUS_LABEL.succeeded).toBe("labels.workflowStatus.succeeded");
  });
});
