import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
	client: { query: vi.fn(), mutate: vi.fn() },
}));

import { client } from "./apollo-client";
import {
	fetchPublicOfferings,
	fetchPublicOffering,
	parseSponsorshipTiers,
	submitEnrollment,
} from "./public-offerings";

const queryMock = vi.mocked(client.query);
const mutateMock = vi.mocked(client.mutate);

const eventRows = [
	{
		id: "evt1",
		slug: "campus-hack",
		title: "Campus Hack",
		status: "open",
		visibility: "public",
		enrollmentPolicy: "open",
		registrationDeadline: "2026-09-01T00:00:00Z",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
});

describe("fetchPublicOfferings（E-5 #50 公开发现页数据层）", () => {
	it("event 走 PUBLIC_LIST_EVENTS，返回 results；空 → []", async () => {
		queryMock.mockResolvedValue({ data: { listEvents: { results: eventRows } } });

		const rows = await fetchPublicOfferings("event");
		expect(rows).toEqual(eventRows);
		expect(queryMock).toHaveBeenCalledWith({ query: expect.anything() });
	});

	it("course 走 PUBLIC_LIST_COURSES，无数据 → []", async () => {
		queryMock.mockResolvedValue({ data: { listCourses: { results: [] } } });

		const rows = await fetchPublicOfferings("course");
		expect(rows).toEqual([]);
	});
});

describe("fetchPublicOffering（E-5 #50 公开宿主页）", () => {
	it("event 按 slug 返回条目", async () => {
		queryMock.mockResolvedValue({ data: { getEventBySlug: eventRows[0] } });

		const row = await fetchPublicOffering("campus-hack", "event");
		expect(row?.title).toBe("Campus Hack");
		expect(queryMock).toHaveBeenCalledWith({
			query: expect.anything(),
			variables: { slug: "campus-hack" },
		});
	});

	it("workspace-only / 非 open → null（404 语义）", async () => {
		queryMock.mockResolvedValue({ data: { getCourseBySlug: null } });

		const row = await fetchPublicOffering("hidden-course", "course");
		expect(row).toBeNull();
	});
});

describe("submitEnrollment（E-5 #50 createEnrollment mutation 契约）", () => {
	it("提交 input 并返回 result", async () => {
		mutateMock.mockResolvedValue({
			data: {
				createEnrollment: { result: { id: "enr1", status: "confirmed" }, errors: [] },
			},
		});

		const res = await submitEnrollment({
			eventId: "evt1",
			userId: "u1",
			inviteCode: null,
		});

		expect(res.result?.status).toBe("confirmed");
		expect(mutateMock).toHaveBeenCalledWith({
			mutation: expect.anything(),
			variables: { input: { eventId: "evt1", userId: "u1", inviteCode: null } },
		});
	});

	it("后端错误 → errors 数组透传", async () => {
		mutateMock.mockResolvedValue({
			data: {
				createEnrollment: {
					result: null,
					errors: [{ message: "capacity is full" }],
				},
			},
		});

		const res = await submitEnrollment({ courseId: "c1", userId: "u1" });
		expect(res.result).toBeNull();
		expect(res.errors[0]?.message).toBe("capacity is full");
	});
});

describe("parseSponsorshipTiers（E-3 #48 JsonString 数组解析）", () => {
	it("合法档位解析为 SponsorshipTierConfig（snake_case → camelCase）", () => {
		const tiers = parseSponsorshipTiers([
			JSON.stringify({
				id: "t1",
				name: "冠名",
				amount_suggestion: 10000,
				benefits: ["logo"],
				exclusive: true,
			}),
		]);

		expect(tiers).toEqual([
			{
				id: "t1",
				name: "冠名",
				amountSuggestion: 10000,
				benefits: ["logo"],
				exclusive: true,
			},
		]);
	});

	it("结构非法项静默丢弃；null/非数组 → []", () => {
		expect(parseSponsorshipTiers(["not-json", JSON.stringify({ id: "x" })])).toEqual([]);
		expect(parseSponsorshipTiers(null)).toEqual([]);
		expect(parseSponsorshipTiers(undefined)).toEqual([]);
	});
});
