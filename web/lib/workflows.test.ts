import { describe, expect, it, vi } from "vitest";
import { fetchWorkflowRuns } from "./workflows";

const queryMock = vi.hoisted(() => vi.fn());
vi.mock("./apollo-client", () => ({ client: { query: queryMock } }));

describe("redacted workflow audit adapter", () => {
  it("does not issue a raw workflow query for Workspace members", async () => {
    expect(await fetchWorkflowRuns("ws_1")).toEqual([]);
    expect(queryMock).not.toHaveBeenCalled();
  });

  it("maps the platform audit response without facts", async () => {
    queryMock.mockResolvedValueOnce({
      data: {
        platformWorkflowAudit: [{
          id: "run-1",
          workspaceId: "ws-1",
          definitionType: "learning",
          status: "succeeded",
          startedAt: "2026-08-01T00:00:00Z",
          finishedAt: "2026-08-01T00:01:00Z",
          insertedAt: "2026-08-01T00:00:00Z",
        }],
      },
    });
    const rows = await fetchWorkflowRuns(undefined, { filters: { status: "succeeded" } });
    expect(rows[0]).toMatchObject({ id: "run-1", definitionType: "learning", facts: {}, steps: [] });
    expect(queryMock).toHaveBeenCalledWith(expect.objectContaining({ variables: { status: "succeeded" } }));
  });
});
