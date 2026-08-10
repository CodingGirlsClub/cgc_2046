import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
  APPROVE_WORKSPACE_APPLICATION,
  DEMOTE_USER,
  LIST_PENDING_OPERATIONS,
  LIST_SIGNAL_LOGS,
  LIST_TOOL_CALL_LOGS,
  LIST_USERS,
  LIST_WORKSPACE_APPLICATIONS,
  LIST_WORKSPACES,
  MY_WORKSPACE_APPLICATIONS,
  PROMOTE_USER,
  REJECT_WORKSPACE_APPLICATION,
} from "./admin";

describe("admin GraphQL 契约（Phase 5 后端 schema 对齐）", () => {
  it("listUsers 查询含 admin 字段与分页参数", () => {
    const doc = print(LIST_USERS);
    expect(doc).toContain("query ListUsers($search: String, $first: Int, $after: String)");
    expect(doc).toContain("listUsers(search: $search, first: $first, after: $after)");
    expect(doc).toContain("workspaceMembershipCount");
    expect(doc).toContain("isPlatformAdmin");
  });

  it("listWorkspaces 查询含 admin 字段", () => {
    const doc = print(LIST_WORKSPACES);
    expect(doc).toContain("query ListWorkspaces");
    expect(doc).toContain("listWorkspaces(search: $search");
    expect(doc).toContain("memberCount");
    expect(doc).toContain("joinPolicy");
  });

  it("listWorkspaceApplications 含 status 过滤与申请字段", () => {
    const doc = print(LIST_WORKSPACE_APPLICATIONS);
    expect(doc).toContain("query ListWorkspaceApplications");
    expect(doc).toContain("listWorkspaceApplications(status: $status");
    expect(doc).toContain("applicantId");
    expect(doc).toContain("rejectionReason");
  });

  it("myWorkspaceApplications 返回申请人自己的申请", () => {
    const doc = print(MY_WORKSPACE_APPLICATIONS);
    expect(doc).toContain("query MyWorkspaceApplications");
    expect(doc).toContain("myWorkspaceApplications");
  });

  it("审计日志查询（ToolCallLog/PendingOperation/SignalLog）带 workspaceId 过滤", () => {
    const logs = print(LIST_TOOL_CALL_LOGS);
    expect(logs).toContain("query ListToolCallLogs");
    expect(logs).toContain("listToolCallLogs(workspaceId: $workspaceId");
    expect(logs).toContain("resultStatus");

    const ops = print(LIST_PENDING_OPERATIONS);
    expect(ops).toContain("query ListPendingOperations");
    expect(ops).toContain("listPendingOperations(workspaceId: $workspaceId");

    const signals = print(LIST_SIGNAL_LOGS);
    expect(signals).toContain("query ListSignalLogs");
    expect(signals).toContain("listSignalLogs(workspaceId: $workspaceId");
  });

  it("approve/reject mutation 返回 result + errors", () => {
    const approve = print(APPROVE_WORKSPACE_APPLICATION);
    expect(approve).toContain("mutation ApproveWorkspaceApplication($id: ID!)");
    expect(approve).toContain("approveWorkspaceApplication(id: $id)");
    expect(approve).toContain("errors {");

    const reject = print(REJECT_WORKSPACE_APPLICATION);
    expect(reject).toContain("mutation RejectWorkspaceApplication");
    expect(reject).toContain("rejectWorkspaceApplication(id: $id, input: $input)");
    expect(reject).toContain("rejectionReason");
  });

  it("promote/demote mutation 返回 AdminUserPayload", () => {
    const promote = print(PROMOTE_USER);
    expect(promote).toContain("mutation PromoteUser($id: ID!)");
    expect(promote).toContain("promoteUser(id: $id)");
    expect(promote).toContain("isPlatformAdmin");

    const demote = print(DEMOTE_USER);
    expect(demote).toContain("mutation DemoteUser($id: ID!)");
    expect(demote).toContain("demoteUser(id: $id)");
  });
});
