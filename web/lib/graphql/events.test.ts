import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
	EVENT_STATUS_LABEL,
	EVENT_STATUS_TONE,
	VISIBILITY_LABEL,
	ENROLLMENT_POLICY_LABEL,
	OFFERING_LABEL,
	LIST_EVENTS,
	LIST_COURSES,
	GET_EVENT,
	GET_COURSE,
	CREATE_EVENT,
	CREATE_COURSE,
	UPDATE_EVENT,
	LAUNCH_EVENT,
	CLOSE_EVENT,
	CANCEL_EVENT,
	LIST_EVENT_ENROLLMENTS,
} from "./events";
import { allowedTransitions } from "../events";

describe("events GraphQL 契约（对齐 event.ex/course.ex graphql 段 + schema.graphql）", () => {
	it("LIST_EVENTS：keyset 分页 + filter 参数（真实 schema：filter 包裹 + results）", () => {
		const doc = print(LIST_EVENTS);
		expect(doc).toContain("query ListEvents($workspaceId: ID!)");
		expect(doc).toContain("listEvents(filter: { workspaceId: { eq: $workspaceId } })");
		expect(doc).toContain("results {");
		expect(doc).toContain("status");
		expect(doc).toContain("visibility");
		expect(doc).toContain("enrollmentPolicy");
		expect(doc).toContain("capacity");
		expect(doc).toContain("confirmedCount");
		expect(doc).toContain("registrationDeadline");
	});

	it("LIST_COURSES / GET_EVENT / GET_COURSE 同构齐全", () => {
		expect(print(LIST_COURSES)).toContain("listCourses(filter: { workspaceId: { eq: $workspaceId } })");
		expect(print(GET_EVENT)).toContain("getEvent(id: $id)");
		expect(print(GET_COURSE)).toContain("getCourse(id: $id)");
	});

	it("CREATE / UPDATE / LAUNCH / CLOSE / CANCEL（Event 与 Course 双文档）", () => {
		expect(print(CREATE_EVENT)).toContain("mutation CreateEvent($input: CreateEventInput!)");
		expect(print(CREATE_COURSE)).toContain("mutation CreateCourse($input: CreateCourseInput!)");
		expect(print(UPDATE_EVENT)).toContain("updateEvent(id: $id, input: $input)");
		expect(print(LAUNCH_EVENT)).toContain("launchEvent(id: $id)");
		expect(print(CLOSE_EVENT)).toContain("closeEvent(id: $id)");
		expect(print(CANCEL_EVENT)).toContain("cancelEvent(id: $id)");
	});

	it("LIST_EVENT_ENROLLMENTS：pending 计数（详情页报名数据视图）", () => {
		const doc = print(LIST_EVENT_ENROLLMENTS);
		expect(doc).toContain('enrollments(filter: { eventId: { eq: $eventId }, status: { eq: "pending" } })');
		expect(doc).toContain("count");
	});
});

describe("events 展示词表", () => {
	it("状态/可见性/策略/kind 词表覆盖全部枚举", () => {
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
		expect(OFFERING_LABEL.event).toBe("活动");
		expect(OFFERING_LABEL.course).toBe("课程");
	});
});

describe("events 状态机前置守卫", () => {
	it("draft 仅 launch；open 可 close/cancel；终态不可再动作（v1 不可逆）", () => {
		expect(allowedTransitions("draft")).toEqual(["launch"]);
		expect(allowedTransitions("open").sort()).toEqual(["cancel", "close"]);
		expect(allowedTransitions("closed")).toEqual([]);
		expect(allowedTransitions("cancelled")).toEqual([]);
	});
});
