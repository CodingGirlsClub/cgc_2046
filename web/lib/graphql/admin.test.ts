import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
  APPROVE_WORKSPACE_APPLICATION,
  DEMOTE_USER,
  LIST_ADMIN_ACTION_LOGS,
  LIST_PENDING_OPERATIONS,
  LIST_SIGNAL_LOGS,
  LIST_TOOL_CALL_LOGS,
  LIST_USERS,
  LIST_WORKSPACE_APPLICATIONS,
  LIST_WORKSPACES,
  MY_WORKSPACE_APPLICATIONS,
  RECONCILIATION_ENTITY_LABEL,
  RECONCILIATION_RULE_LABEL,
  PROMOTE_USER,
  REJECT_WORKSPACE_APPLICATION,
} from "./admin";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

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

  it("审计日志查询（ToolCallLog/PendingOperation/SignalLog）带 workspaceId + 筛选参数（#117）", () => {
    const logs = print(LIST_TOOL_CALL_LOGS);
    expect(logs).toContain("query ListToolCallLogs");
    expect(logs).toContain("listToolCallLogs(");
    expect(logs).toContain("workspaceId: $workspaceId");
    expect(logs).toContain("status: $status");
    expect(logs).toContain("insertedAfter: $insertedAfter");
    expect(logs).toContain("insertedBefore: $insertedBefore");
    expect(logs).toContain("resultStatus");

    const ops = print(LIST_PENDING_OPERATIONS);
    expect(ops).toContain("query ListPendingOperations");
    expect(ops).toContain("workspaceId: $workspaceId");
    expect(ops).toContain("status: $status");

    const signals = print(LIST_SIGNAL_LOGS);
    expect(signals).toContain("query ListSignalLogs");
    expect(signals).toContain("workspaceId: $workspaceId");
    expect(signals).toContain("signalType: $signalType");
    expect(signals).toContain("insertedAfter: $insertedAfter");

    const actions = print(LIST_ADMIN_ACTION_LOGS);
    expect(actions).toContain("query ListAdminActionLogs");
    expect(actions).toContain("action: $action");
    expect(actions).toContain("insertedAfter: $insertedAfter");
    expect(actions).not.toContain("status: $status");
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

  it("listAdminActionLogs 带 #607 metadata 白名单投影字段", () => {
    const doc = print(LIST_ADMIN_ACTION_LOGS);
    expect(doc).toContain("metadata {");
    for (const field of [
      "ruleKey",
      "locked",
      "lockedBefore",
      "valueBeforeJson",
      "valueAfterJson",
      "valueBeforeOmitted",
      "valueAfterOmitted",
    ]) {
      expect(doc).toContain(field);
    }
  });
});

describe("对账规则标签契约（对齐 backend finding.ex @rule_values；#852）", () => {
  const HERE = dirname(fileURLToPath(import.meta.url));
  const FINDING_EX = resolve(HERE, "../../../backend/lib/cgc_2046/reconciliation/finding.ex");
  const MESSAGES = resolve(HERE, "../../messages");

  function backendRuleAtoms(): string[] {
    const block = readFileSync(FINDING_EX, "utf8").match(/@rule_values \[([^\]]+)\]/)?.[1] ?? "";
    return [...block.matchAll(/^\s*:([a-z_]+),?\s*$/gm)].map((m) => m[1]);
  }

  it("RECONCILIATION_RULE_LABEL 键集与后端 @rule_values 完全一致（双向，防任一侧静默漂移）", () => {
    const backend = backendRuleAtoms();
    // 空集假绿防线：后端实有 18 条，提取器失效（返回 0/少量）必须红
    expect(backend.length).toBeGreaterThanOrEqual(18);
    expect(Object.keys(RECONCILIATION_RULE_LABEL).sort()).toEqual([...backend].sort());
  });

  it("每个标签 i18n key 在 zh-CN / en 的 labels.reconRule 下都有文案", () => {
    const zh = JSON.parse(readFileSync(resolve(MESSAGES, "zh-CN.json"), "utf8"));
    const en = JSON.parse(readFileSync(resolve(MESSAGES, "en.json"), "utf8"));

    for (const [atom, key] of Object.entries(RECONCILIATION_RULE_LABEL)) {
      expect(key).toBe(`labels.reconRule.${atom}`);
      expect(zh.labels.reconRule[atom], `zh-CN 缺 ${atom} 文案`).toBeTruthy();
      expect(en.labels.reconRule[atom], `en 缺 ${atom} 文案`).toBeTruthy();
    }
  });
});

describe("对账实体标签契约（对齐 backend finding.ex @entity_type_values；#916）", () => {
  const HERE = dirname(fileURLToPath(import.meta.url));
  const FINDING_EX = resolve(HERE, "../../../backend/lib/cgc_2046/reconciliation/finding.ex");
  const MESSAGES = resolve(HERE, "../../messages");

  function backendEntityAtoms(): string[] {
    const block = readFileSync(FINDING_EX, "utf8").match(/@entity_type_values \[([^\]]+)\]/)?.[1] ?? "";
    return [...block.matchAll(/^\s*:([a-z_]+),?\s*$/gm)].map((m) => m[1]);
  }

  it("RECONCILIATION_ENTITY_LABEL 键集与后端 @entity_type_values 完全一致（双向，防任一侧静默漂移）", () => {
    const backend = backendEntityAtoms();
    // 空集假绿防线：后端实有 11 条，提取器失效（返回 0/少量）必须红
    expect(backend.length).toBeGreaterThanOrEqual(11);
    expect(Object.keys(RECONCILIATION_ENTITY_LABEL).sort()).toEqual([...backend].sort());
  });

  it("i18n 形态的实体标签在 zh-CN / en 的 labels.reconEntity 下都有文案", () => {
    const zh = JSON.parse(readFileSync(resolve(MESSAGES, "zh-CN.json"), "utf8"));
    const en = JSON.parse(readFileSync(resolve(MESSAGES, "en.json"), "utf8"));

    for (const [atom, key] of Object.entries(RECONCILIATION_ENTITY_LABEL)) {
      // oban_job / workflow_run 是硬编码英文字面量（技术名词不翻译），不做 i18n 断言
      if (!key.startsWith("labels.reconEntity.")) continue;
      expect(key).toBe(`labels.reconEntity.${atom}`);
      expect(zh.labels.reconEntity[atom], `zh-CN 缺 ${atom} 文案`).toBeTruthy();
      expect(en.labels.reconEntity[atom], `en 缺 ${atom} 文案`).toBeTruthy();
    }
  });
});
