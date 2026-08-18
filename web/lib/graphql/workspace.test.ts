import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
	GET_WORKSPACE,
	GET_WORKSPACE_BY_ID,
	CREATE_WORKSPACE,
	ME_WORKSPACES,
	ASSIGN_ROLES,
	WORKSPACE_MEMBERS,
	JOIN_POLICY_LABEL,
	JOIN_POLICY_HINT,
	MEMBERSHIP_ROLES,
	ROLE_LABEL,
	ROLE_LABEL_ZH,
	ROLE_NAMES,
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
		expect(doc).toContain("sponsorshipTiers");
		expect(doc).toContain("memberCount");
	});

	it("GET_WORKSPACE_BY_ID：id 参数", () => {
		const doc = print(GET_WORKSPACE_BY_ID);
		expect(doc).toContain("query GetWorkspaceById($id: ID!)");
		expect(doc).toContain("getWorkspaceById(id: $id)");
	});

	it("CREATE_WORKSPACE：input 嵌套 + result/errors", () => {
		const doc = print(CREATE_WORKSPACE);
		expect(doc).toContain(
			"mutation CreateWorkspace($input: CreateWorkspaceInput!)",
		);
		expect(doc).toContain("createWorkspace(input: $input)");
		expect(doc).toContain("result {");
		expect(doc).toContain("errors {");
		expect(doc).toContain("message");
		expect(doc).toContain("code");
	});
});

describe("join_policy 展示辅助", () => {
	it("三态标签齐全", () => {
		expect(JOIN_POLICY_LABEL.open).toBe("labels.joinPolicy.open");
		expect(JOIN_POLICY_LABEL.request).toBe("labels.joinPolicy.request");
		expect(JOIN_POLICY_LABEL.invite_only).toBe("labels.joinPolicy.invite_only");
		expect(JOIN_POLICY_HINT.open).toBe("labels.joinPolicyHint.open");
		expect(JOIN_POLICY_HINT.request).toBe("labels.joinPolicyHint.request");
		expect(JOIN_POLICY_HINT.invite_only).toBe("labels.joinPolicyHint.invite_only");
	});
});

describe("#64/#65 成员角色契约", () => {
	it("ME_WORKSPACES：可进入工作台列表含 #64 计算字段", () => {
		const doc = print(ME_WORKSPACES);
		expect(doc).toContain("query MeWorkspaces");
		expect(doc).toContain("meWorkspaces {");
		expect(doc).toContain("myRoleNames");
		expect(doc).toContain("myMembershipId");
		expect(doc).toContain("canAccess");
	});

	it("ASSIGN_ROLES：id + roleNames 输入，返回 WorkspaceMembership/errors", () => {
		const doc = print(ASSIGN_ROLES);
		expect(doc).toContain(
			"mutation AssignRoles($id: ID!, $input: AssignRolesInput!)",
		);
		expect(doc).toContain("assignRoles(id: $id, input: $input)");
		expect(doc).toContain("result {");
		expect(doc).toContain("workspaceId");
		expect(doc).toContain("userId");
		expect(doc).toContain("roles {");
		expect(doc).toContain("name");
		expect(doc).toContain("errors {");
	});

	it("WORKSPACE_MEMBERS：filter eq 包装 + 分页参数 + 游标 + count/results + roles{id,name}", () => {
		const doc = print(WORKSPACE_MEMBERS);
		expect(doc).toContain(
			"query WorkspaceMembers($filter: WorkspaceMembershipFilterInput!, $first: Int, $after: String)",
		);
		expect(doc).toContain("workspaceMembers(filter: $filter, first: $first, after: $after)");
		expect(doc).toContain("count");
		expect(doc).toContain("results {");
		expect(doc).toContain("roles {");
		expect(doc).toContain("id");
		expect(doc).toContain("name");
		expect(doc).toContain("startKeyset");
		expect(doc).toContain("endKeyset");
	});

	it("角色模型：五角色差异标签齐全，无 member 标签", () => {
		// 断言引用 ROLE_NAMES 单源，不重复五角色字面量
		expect(MEMBERSHIP_ROLES).toEqual([...ROLE_NAMES]);
		expect(ROLE_NAMES).toEqual([
			"owner",
			"admin",
			"tutor",
			"volunteer",
			"learner",
		]);
		expect(ROLE_NAMES).not.toContain("member");
		expect(ROLE_LABEL.owner).toBe("labels.role.owner");
		expect(ROLE_LABEL.admin).toBe("labels.role.admin");
		expect(ROLE_LABEL.tutor).toBe("labels.role.tutor");
		expect(ROLE_LABEL.volunteer).toBe("labels.role.volunteer");
		expect(ROLE_LABEL.learner).toBe("labels.role.learner");
		expect(ROLE_LABEL_ZH.owner).toBe("labels.roleZh.owner");
		expect(ROLE_LABEL_ZH.admin).toBe("labels.roleZh.admin");
		expect(ROLE_LABEL_ZH.tutor).toBe("labels.roleZh.tutor");
		expect(ROLE_LABEL_ZH.volunteer).toBe("labels.roleZh.volunteer");
		expect(ROLE_LABEL_ZH.learner).toBe("labels.roleZh.learner");
		expect("member" in ROLE_LABEL).toBe(false);
		expect("member" in ROLE_LABEL_ZH).toBe(false);
	});

	it("ME_WORKSPACES：携带 myRoleNames/myMembershipId/canAccess/myAbilities/memberCount（#1 能力接口字段）", () => {
		const doc = print(ME_WORKSPACES);
		expect(doc).toContain("query MeWorkspaces");
		expect(doc).toContain("myRoleNames");
		expect(doc).toContain("myMembershipId");
		expect(doc).toContain("canAccess");
		expect(doc).toContain("myAbilities");
		expect(doc).toContain("memberCount");
	});
});
