import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
	EVENT_STATUS_LABEL,
	EVENT_STATUS_TONE,
	VISIBILITY_LABEL,
	ENROLLMENT_POLICY_LABEL,
	ENROLLMENT_BADGE_LABEL,
	ENROLLMENT_BADGES,
	OFFERING_LABEL,
	LIST_EVENTS,
	LIST_COURSES,
	GET_EVENT,
	GET_COURSE,
	CREATE_EVENT,
	CREATE_COURSE,
	UPDATE_EVENT,
	UPDATE_COURSE,
	LAUNCH_EVENT,
	CLOSE_EVENT,
	CANCEL_EVENT,
	PUBLIC_LIST_EVENTS,
	PUBLIC_LIST_COURSES,
	PUBLIC_GET_EVENT,
	PUBLIC_GET_COURSE,
	LIST_EVENT_ENROLLMENTS,
	MY_EVENT_ENROLLMENT,
	MY_COURSE_ENROLLMENT,
	MY_ENROLLMENT,
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

	it("MY_EVENT/COURSE_ENROLLMENT：活跃态过滤（终态不挡再报名，e2e #2）+ status 透传", () => {
		const eventDoc = print(MY_EVENT_ENROLLMENT);
		expect(eventDoc).toContain("query MyEventEnrollment($eventId: ID!, $userId: ID!)");
		expect(eventDoc).toContain(
			'status: { in: ["pending", "payment_pending", "confirmed"] }',
		);
		expect(eventDoc).toContain("results {\n      id\n      status\n    }");

		const courseDoc = print(MY_COURSE_ENROLLMENT);
		expect(courseDoc).toContain("query MyCourseEnrollment($courseId: ID!, $userId: ID!)");
		expect(courseDoc).toContain(
			'status: { in: ["pending", "payment_pending", "confirmed"] }',
		);
		expect(courseDoc).toContain("results {\n      id\n      status\n    }");
	});

	it("MY_ENROLLMENT：按 id 读本人报名（/orders/new 守卫）", () => {
		const doc = print(MY_ENROLLMENT);
		expect(doc).toContain("query MyEnrollment($id: ID!)");
		expect(doc).toContain("myEnrollments(filter: { id: { eq: $id } })");
		expect(doc).toContain("results {\n      id\n      status\n    }");
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
		expect(OFFERING_LABEL.event).toBe("labels.offeringKind.event");
		expect(OFFERING_LABEL.course).toBe("labels.offeringKind.course");
	});

	it("badge 词表覆盖 KTD1 三枚举（enrolling/starting_soon/full）", () => {
		expect(Object.keys(ENROLLMENT_BADGE_LABEL).sort()).toEqual(
			["enrolling", "full", "starting_soon"].sort(),
		);
		expect(ENROLLMENT_BADGES.sort()).toEqual(
			["enrolling", "full", "starting_soon"].sort(),
		);
		expect(ENROLLMENT_BADGE_LABEL.enrolling).toBe("labels.enrollmentBadge.enrolling");
		expect(ENROLLMENT_BADGE_LABEL.starting_soon).toBe(
			"labels.enrollmentBadge.starting_soon",
		);
		expect(ENROLLMENT_BADGE_LABEL.full).toBe("labels.enrollmentBadge.full");
	});
});

describe("公开面查询（R10 同一匿名通道扩展字段；R6 badge；R3 时间/venue 可空）", () => {
	it("PUBLIC_LIST_EVENTS：带 startsAt/endsAt/enrollmentBadge/venue", () => {
		const doc = print(PUBLIC_LIST_EVENTS);
		expect(doc).toContain(
			'listEvents(filter: { status: { eq: "open" }, visibility: { eq: "public" } })',
		);
		for (const field of [
			"startsAt",
			"endsAt",
			"enrollmentBadge",
			"venue",
		]) {
			expect(doc).toContain(field);
		}
	});

	it("PUBLIC_LIST_COURSES：带 startsAt/endsAt/enrollmentBadge（course 无 venue 槽）", () => {
		const doc = print(PUBLIC_LIST_COURSES);
		expect(doc).toContain(
			'listCourses(filter: { status: { eq: "open" }, visibility: { eq: "public" } })',
		);
		for (const field of ["startsAt", "endsAt", "enrollmentBadge"]) {
			expect(doc).toContain(field);
		}
		expect(doc).not.toContain("venue");
	});

	it("PUBLIC_GET_EVENT / PUBLIC_GET_COURSE：详情同步带时间+badge（event 另带 venue）", () => {
		const eventDoc = print(PUBLIC_GET_EVENT);
		expect(eventDoc).toContain("getEventBySlug(slug: $slug)");
		for (const field of [
			"startsAt",
			"endsAt",
			"enrollmentBadge",
			"venue",
		]) {
			expect(eventDoc).toContain(field);
		}

		const courseDoc = print(PUBLIC_GET_COURSE);
		expect(courseDoc).toContain("getCourseBySlug(slug: $slug)");
		for (const field of ["startsAt", "endsAt", "enrollmentBadge"]) {
			expect(courseDoc).toContain(field);
		}
		expect(courseDoc).not.toContain("venue");
	});
});

describe("成员读写面（U5/R14：Owner 表单预填与保存回读）", () => {
	it("GET_EVENT / GET_COURSE：带 startsAt/endsAt（event 另带 venue JsonString；course 无 venue 槽）", () => {
		const eventDoc = print(GET_EVENT);
		for (const field of ["startsAt", "endsAt", "venue"]) {
			expect(eventDoc).toContain(field);
		}

		const courseDoc = print(GET_COURSE);
		for (const field of ["startsAt", "endsAt"]) {
			expect(courseDoc).toContain(field);
		}
		expect(courseDoc).not.toContain("venue");
	});

	it("UPDATE_EVENT / UPDATE_COURSE：result 带回 startsAt/endsAt（event 另带 venue）供局部状态更新", () => {
		const eventDoc = print(UPDATE_EVENT);
		for (const field of ["startsAt", "endsAt", "venue"]) {
			expect(eventDoc).toContain(field);
		}

		const courseDoc = print(UPDATE_COURSE);
		for (const field of ["startsAt", "endsAt"]) {
			expect(courseDoc).toContain(field);
		}
		expect(courseDoc).not.toContain("venue");
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
