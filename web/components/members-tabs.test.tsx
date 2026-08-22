import { describe, it, expect, afterEach } from "vitest";
import { cleanup, screen, within } from "@testing-library/react";
import { render } from "@/test-utils";
import MembersTabs from "./members-tabs";

describe("MembersTabs（plan 016 门控单源：消费 SETTINGS_NAV）", () => {
	afterEach(() => cleanup());

	it("无 manage_members：成员/权限/加入策略可见，加入审批/邀请管理 tab 不渲染", () => {
		render(
			<MembersTabs
				slug="cgc-academy"
				current="members"
				abilities={["list_members", "update_join_policy"]}
			/>,
		);
		const tabs = screen.getByRole("navigation", { name: "工作区设置页签" });
		expect(
			within(tabs).getByRole("link", { name: "成员与角色" }),
		).toHaveAttribute("href", "/w/cgc-academy/settings/members");
		expect(
			within(tabs).getByRole("link", { name: "权限映射" }),
		).toHaveAttribute("href", "/w/cgc-academy/settings/permissions");
		expect(
			within(tabs).getByRole("link", { name: "加入策略" }),
		).toHaveAttribute("href", "/w/cgc-academy/settings/join-policy");
		expect(
			within(tabs).queryByRole("link", { name: "加入审批" }),
		).not.toBeInTheDocument();
		expect(
			within(tabs).queryByRole("link", { name: "邀请管理" }),
		).not.toBeInTheDocument();
	});

	it("有 manage_members：五个 tab 全部渲染，当前 tab 高亮", () => {
		render(
			<MembersTabs
				slug="cgc-academy"
				current="requests"
				abilities={["list_members", "update_join_policy", "manage_members"]}
			/>,
		);
		const tabs = screen.getByRole("navigation", { name: "工作区设置页签" });
		expect(
			within(tabs).getByRole("link", { name: "加入审批" }),
		).toHaveAttribute("href", "/w/cgc-academy/settings/requests");
		expect(
			within(tabs).getByRole("link", { name: "邀请管理" }),
		).toHaveAttribute("href", "/w/cgc-academy/settings/invitations");
		expect(
			within(tabs).getByRole("link", { name: "加入审批" }),
		).toHaveAttribute("aria-current", "page");
	});

	it("普通成员（无任何管理能力）：门控 tab 全部不渲染（2026-08-22 决策）", () => {
		render(
			<MembersTabs
				slug="cgc-academy"
				current="members"
				abilities={["view_workspace", "access_invite_only"]}
			/>,
		);
		const tabs = screen.getByRole("navigation", { name: "工作区设置页签" });
		// 成员/权限 = list_members，加入策略 = update_join_policy，审批/邀请/缴费 = manage_members
		for (const name of [
			"成员与角色",
			"权限映射",
			"加入策略",
			"加入审批",
			"邀请管理",
			"缴费管理",
			"赞助管理",
		]) {
			expect(
				within(tabs).queryByRole("link", { name }),
			).not.toBeInTheDocument();
		}
	});
});
