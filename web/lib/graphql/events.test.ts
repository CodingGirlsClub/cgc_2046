import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
	EVENT_STATUS_LABEL,
	EVENT_STATUS_TONE,
	VISIBILITY_LABEL,
	ENROLLMENT_POLICY_LABEL,
	LIST_EVENTS,
	GET_EVENT,
	CREATE_EVENT,
	UPDATE_EVENT,
	LAUNCH_EVENT,
	CLOSE_EVENT,
	CANCEL_EVENT,
} from "./events";
import { allowedTransitions } from "../events";

describe("events GraphQL 契约（对齐 event.ex/course.ex graphql 段）", () => {
	it("LIST_EVENTS：workspaceId 过滤 + 全字段（含 D2 白名单字段）", () => {
		const doc = print(LIST_EVENTS);
		expect(doc).toContain("query ListEvents($workspaceId: ID!)");
		expect(doc).toContain("listEvents(input: { workspaceId: $workspaceId })");
		expect(doc).toContain("status");
		expect(doc).toContain("visibility");
		expect(doc).toContain("enrollmentPolicy");
		expect(doc).toContain("capacity");
		expect(doc).toContain("confirmedCount");
		expect(doc).toContain("registrationDeadline");
	});

	it("GET_EVENT：按 id 取详情", () => {
		const doc = print(GET_EVENT);
		expect(doc).toContain("query GetEvent($id: ID!)");
		expect(doc).toContain("getEvent(id: $id)");
	});

	it("CREATE_EVENT：workspaceId 入参（GraphQL 不注入 tenant 的派生约定）", () => {
		const doc = print(CREATE_EVENT);
		expect(doc).toContain("mutation CreateEvent($input: CreateEventInput!)");
		expect(doc).toContain("createEvent(input: $input)");
	});

	it("UPDATE_EVENT / LAUNCH / CLOSE / CANCEL：管理动作齐全", () => {
		expect(print(UPDATE_EVENT)).toContain("updateEvent(id: $id, input: $input)");
		expect(print(LAUNCH_EVENT)).toContain("launchEvent(id: $id)");
		expect(print(CLOSE_EVENT)).toContain("closeEvent(id: $id)");
		expect(print(CANCEL_EVENT)).toContain("cancelEvent(id: $id)");
	});
});

describe("events 展示词表", () => {
	it("状态/可见性/策略词表覆盖全部枚举", () => {
		expect(Object.keys(EVENT_STATUS_LABEL).sort()).toEqual(
			["cancelled", "closed", "draft", "open"].sort(),
		);
		expect(Object.keys(EVENT_STATUS_TONE).sort()).toEqual(
			["cancelled", "closed", "draft", "open"].sort(),
		);
		expect(Object.keys(VISIBILITY_LABEL).sort()).toEqual(["public", "workspace"]);
		expect(Object.keys(ENROLLMENT_POLICY_LABEL).sort()).toEqual([
			"invite_only",
			"open",
			"request",
		]);
	});
});

describe("events 状态机前置守卫", () => {
	it("draft 可 launch/cancel；open 可 close/cancel；终态不可再动作（v1 不可逆）", () => {
		expect(allowedTransitions("draft").sort()).toEqual(["cancel", "launch"]);
		expect(allowedTransitions("open").sort()).toEqual(["cancel", "close"]);
		expect(allowedTransitions("closed")).toEqual([]);
		expect(allowedTransitions("cancelled")).toEqual([]);
	});
});
