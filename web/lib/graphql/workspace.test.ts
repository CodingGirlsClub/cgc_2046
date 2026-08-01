import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
  GET_WORKSPACE,
  GET_WORKSPACE_BY_ID,
  CREATE_WORKSPACE,
  JOIN_POLICY_LABEL,
  JOIN_POLICY_HINT,
} from "./workspace";

describe("workspace GraphQL 契约（对齐 #62 schema）", () => {
  it("GET_WORKSPACE：slug 参数 + Workspace 平铺字段", () => {
    const doc = print(GET_WORKSPACE);
    expect(doc).toContain("query GetWorkspace($slug: String!)");
    expect(doc).toContain("getWorkspace(slug: $slug)");
    expect(doc).toContain("id");
    expect(doc).toContain("slug");
    expect(doc).toContain("name");
    expect(doc).toContain("joinPolicy");
    expect(doc).toContain("sponsorshipEnabled");
  });

  it("GET_WORKSPACE_BY_ID：id 参数", () => {
    const doc = print(GET_WORKSPACE_BY_ID);
    expect(doc).toContain("query GetWorkspaceById($id: ID!)");
    expect(doc).toContain("getWorkspaceById(id: $id)");
  });

  it("CREATE_WORKSPACE：input 嵌套 + result/errors", () => {
    const doc = print(CREATE_WORKSPACE);
    expect(doc).toContain("mutation CreateWorkspace($input: CreateWorkspaceInput!)");
    expect(doc).toContain("createWorkspace(input: $input)");
    expect(doc).toContain("result {");
    expect(doc).toContain("errors {");
    expect(doc).toContain("message");
    expect(doc).toContain("code");
  });
});

describe("join_policy 展示辅助", () => {
  it("三态标签齐全", () => {
    expect(JOIN_POLICY_LABEL.open).toBe("公开");
    expect(JOIN_POLICY_LABEL.request).toBe("申请审批");
    expect(JOIN_POLICY_LABEL.invite_only).toBe("仅邀请");
    expect(JOIN_POLICY_HINT.open).toBe("公开直接加入");
    expect(JOIN_POLICY_HINT.request).toBe("公开申请审批");
    expect(JOIN_POLICY_HINT.invite_only).toBe("私密仅邀请");
  });
});
