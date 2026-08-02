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
		expect(JOIN_POLICY_LABEL.open).toBe("公开");
		expect(JOIN_POLICY_LABEL.request).toBe("申请审批");
		expect(JOIN_POLICY_LABEL.invite_only).toBe("仅邀请");
		expect(JOIN_POLICY_HINT.open).toBe("公开直接加入");
		expect(JOIN_POLICY_HINT.request).toBe("公开申请审批");
		expect(JOIN_POLICY_HINT.invite_only).toBe("私密仅邀请");
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

	it("WORKSPACE_MEMBERS：filter eq 包装 + 分页对象 count/results + roles{id,name}", () => {
		const doc = print(WORKSPACE_MEMBERS);
		expect(doc).toContain(
			"query WorkspaceMembers($filter: WorkspaceMembershipFilterInput!)",
		);
		expect(doc).toContain("workspaceMembers(filter: $filter)");
		expect(doc).toContain("count");
		expect(doc).toContain("results {");
		expect(doc).toContain("roles {");
		expect(doc).toContain("id");
		expect(doc).toContain("name");
	});

	it("角色模型：旧 member 与 Slice A 默认角色标签齐全（六角色）", () => {
		// 断言引用 ROLE_NAMES 单源，不重复六角色字面量
		expect(MEMBERSHIP_ROLES).toEqual([...ROLE_NAMES]);
		expect(ROLE_LABEL.owner).toBe("Owner");
		expect(ROLE_LABEL.admin).toBe("Admin");
		expect(ROLE_LABEL.tutor).toBe("Tutor");
		expect(ROLE_LABEL.volunteer).toBe("Volunteer");
		expect(ROLE_LABEL.learner).toBe("Learner");
		expect(ROLE_LABEL.member).toBe("Member");
		expect(ROLE_LABEL_ZH.owner).toBe("所有者");
		expect(ROLE_LABEL_ZH.admin).toBe("管理员");
		expect(ROLE_LABEL_ZH.tutor).toBe("教练");
		expect(ROLE_LABEL_ZH.volunteer).toBe("志愿者");
		expect(ROLE_LABEL_ZH.learner).toBe("学员");
		expect(ROLE_LABEL_ZH.member).toBe("成员");
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
