import { describe, it, expect, vi, beforeEach } from "vitest";
import { ApolloClient, ApolloLink, InMemoryCache, Observable } from "@apollo/client";

vi.mock("./apollo-client", () => ({
	client: { query: vi.fn(), mutate: vi.fn() },
}));

import { client } from "./apollo-client";
import {
	fetchPublicOfferings,
	fetchPublicOffering,
	formatVenue,
	parseSponsorshipTiers,
	parseVenue,
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
		expect(queryMock).toHaveBeenCalledWith({
			query: expect.anything(),
			fetchPolicy: "network-only",
		});
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
			fetchPolicy: "network-only",
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

describe("parseVenue / formatVenue（R3 venue JsonString 展示兜底）", () => {
	it("合法 venue 解析为四键 VenueInfo，formatVenue 跳过空段单行连接", () => {
		const venue = parseVenue(
			JSON.stringify({ country: "中国", province: "", city: "上海", district: "徐汇" }),
		);

		expect(venue).toEqual({
			country: "中国",
			province: "",
			city: "上海",
			district: "徐汇",
		});
		expect(formatVenue(venue)).toBe("中国 上海 徐汇");
	});

	it("null/非法 JSON/缺键 → null；formatVenue(null) → null（展示层兜底「地点待定」）", () => {
		expect(parseVenue(null)).toBeNull();
		expect(parseVenue(undefined)).toBeNull();
		expect(parseVenue("not-json")).toBeNull();
		expect(parseVenue(JSON.stringify({ country: "中国" }))).toBeNull();
		expect(formatVenue(null)).toBeNull();
	});

	it("四段全空 → formatVenue 返回 null（不出现空白地点）", () => {
		const venue = parseVenue(
			JSON.stringify({ country: "", province: "", city: "", district: "" }),
		);

		expect(venue).not.toBeNull();
		expect(formatVenue(venue)).toBeNull();
	});
});

describe("公开读 network-only（F4：报名失败后重拉不吃缓存旧 badge）", () => {
	/** 真实 ApolloClient（InMemoryCache + 可计数终止 link）：queryMock 委托给它，
	 * fetchPolicy/缓存管线走真实实现（参数断言 mock 不了缓存命中路径）。 */
	function makeNetworkCountedClient() {
		let calls = 0;
		const queue: Array<Record<string, unknown>> = [];
		const real = new ApolloClient({
			link: new ApolloLink(
				() =>
					new Observable((observer) => {
						// 逐调用返回队列中响应（队空复用最后一个）：模拟服务端 badge 演进
						const data = queue[Math.min(calls, queue.length - 1)];
						calls += 1;
						observer.next({ data });
						observer.complete();
					}),
			),
			cache: new InMemoryCache(),
		});
		return {
			real,
			enqueue: (data: Record<string, unknown>) => queue.push(data),
			networkCalls: () => calls,
		};
	}

	// 覆盖 PUBLIC_GET_EVENT / PUBLIC_LIST_EVENTS 请求的全部字段：
	// 字段不全会让 InMemoryCache 判定缓存不完整 → cache-first 也穿透网络，
	// F4 失败形态就复现不出来了（首轮实测教训）
	const row = (badge: string) => ({
		__typename: "Event",
		id: "evt-1",
		slug: "slug-1",
		title: "badge 演进活动",
		description: null,
		status: "open",
		visibility: "public",
		enrollmentPolicy: "open",
		registrationDeadline: null,
		startsAt: "2026-09-01T10:00:00Z",
		endsAt: "2026-09-01T12:00:00Z",
		enrollmentBadge: badge,
		venue: null,
		sponsorshipEnabled: false,
		sponsorshipTiers: null,
		pricingEnabled: false,
		availablePriceTiers: null,
	});

	it("fetchPublicOffering：预热缓存后服务端派发新 badge，第二次读必须再走网络并返回新值", async () => {
		const net = makeNetworkCountedClient();
		queryMock.mockImplementation((options) =>
			net.real.query(options as Parameters<typeof net.real.query>[0]),
		);

		net.enqueue({ getEventBySlug: row("enrolling") });
		net.enqueue({ getEventBySlug: row("full") });

		const first = await fetchPublicOffering("slug-1", "event");
		expect(first?.enrollmentBadge).toBe("enrolling");
		expect(net.networkCalls()).toBe(1);

		// F4 失败形态（advisor02 link 计数 probe 实证）：cache-first 下第二次读
		// 命中缓存——网络计数停在 1、badge 仍旧值，报名失败后的重拉失效
		const second = await fetchPublicOffering("slug-1", "event");
		expect(net.networkCalls()).toBe(2);
		expect(second?.enrollmentBadge).toBe("full");
	});

	it("fetchPublicOfferings：列表读同样 network-only（两次读两次网络）", async () => {
		const net = makeNetworkCountedClient();
		queryMock.mockImplementation((options) =>
			net.real.query(options as Parameters<typeof net.real.query>[0]),
		);

		net.enqueue({ listEvents: { results: [row("enrolling")] } });
		net.enqueue({ listEvents: { results: [row("full")] } });

		await fetchPublicOfferings("event");
		const second = await fetchPublicOfferings("event");

		expect(net.networkCalls()).toBe(2);
		expect(second[0]?.enrollmentBadge).toBe("full");
	});
});
