import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("./apollo-client", () => ({
	client: { query: vi.fn(), mutate: vi.fn() },
}));

import { client } from "./apollo-client";
import { createOffering, formatDeadline, updateOffering } from "./events";
import {
	CREATE_COURSE,
	CREATE_EVENT,
	UPDATE_COURSE,
	UPDATE_EVENT,
} from "./graphql/events";

const mutateMock = vi.mocked(client.mutate);

function ok(field: string) {
	return { data: { [field]: { result: { id: "off-1" }, errors: [] } } } as never;
}

beforeEach(() => {
	mutateMock.mockReset();
});

describe("createOffering input 组装（U5/R14：时间落键 + venue 组 JsonString map，KTD5）", () => {
	it("event：startsAt/endsAt（UTC ISO）透传落键；venue 四键草稿 trim 后组 JsonString", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(mutation).toBe(CREATE_EVENT);
			expect(variables).toEqual({
				input: {
					workspaceId: "ws-1",
					title: "线下工作坊",
					enrollmentPolicy: "open",
					visibility: "public",
					capacity: null,
					registrationDeadline: null,
					startsAt: "2026-09-01T01:30:00.000Z",
					endsAt: "2026-09-01T04:00:00.000Z",
					venue: JSON.stringify({
						country: "中国",
						province: "浙江省",
						city: "杭州市",
						district: "西湖区",
					}),
				},
			});
			return Promise.resolve(ok("createEvent"));
		});

		await createOffering("ws-1", "event", {
			title: "线下工作坊",
			enrollmentPolicy: "open",
			visibility: "public",
			startsAt: "2026-09-01T01:30:00.000Z",
			endsAt: "2026-09-01T04:00:00.000Z",
			venue: {
				country: " 中国 ",
				province: "浙江省",
				city: "杭州市",
				district: "西湖区",
			},
		});

		expect(mutateMock).toHaveBeenCalledTimes(1);
	});

	it("event：venue 全空（含纯空白）→ venue: null；时间缺省 → null（KTD5 nil 合法）", async () => {
		mutateMock.mockImplementation(({ variables }) => {
			const input = (variables as { input: Record<string, unknown> }).input;
			expect(input.startsAt).toBeNull();
			expect(input.endsAt).toBeNull();
			expect(input.venue).toBeNull();
			return Promise.resolve(ok("createEvent"));
		});

		await createOffering("ws-1", "event", {
			title: "线上分享",
			enrollmentPolicy: "open",
			visibility: "public",
			venue: { country: "  ", province: "", city: "", district: "" },
		});
	});

	it("course：不下发 venue 键（schema 无此字段，误传也剥离）；startsAt/endsAt 落键", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			const input = (variables as { input: Record<string, unknown> }).input;
			expect(mutation).toBe(CREATE_COURSE);
			expect(input).not.toHaveProperty("venue");
			expect(input.startsAt).toBe("2026-09-01T01:30:00.000Z");
			expect(input.endsAt).toBeNull();
			return Promise.resolve(ok("createCourse"));
		});

		await createOffering("ws-1", "course", {
			title: "春季训练营",
			enrollmentPolicy: "open",
			visibility: "public",
			startsAt: "2026-09-01T01:30:00.000Z",
			venue: {
				country: "中国",
				province: "浙江省",
				city: "杭州市",
				district: "西湖区",
			},
		});
	});
});

describe("定价字段透传与回读（review F1/F15：create 落键 + update result 选列）", () => {
	it("create：pricingEnabled 开启时 input 落 pricingEnabled + priceTiers；免费路径两键皆不下发", async () => {
		mutateMock.mockImplementation((opts) => {
			const variables = opts?.variables as { input: Record<string, unknown> };
			expect(variables.input.pricingEnabled).toBe(true);
			expect(variables.input.priceTiers).toEqual([
				JSON.stringify({ id: "t1", name: "标准", amount_cents: 19900 }),
			]);
			return Promise.resolve(ok("createEvent"));
		});

		await createOffering("ws-1", "event", {
			title: "收费工作坊",
			enrollmentPolicy: "open",
			visibility: "public",
			pricingEnabled: true,
			priceTiers: [JSON.stringify({ id: "t1", name: "标准", amount_cents: 19900 })],
		});

		// 免费路径：未传定价 → input 无 pricingEnabled/priceTiers 键（AE4 零额外字段）
		mutateMock.mockImplementation(() => Promise.resolve(ok("createEvent")));
		await createOffering("ws-1", "event", {
			title: "免费工作坊",
			enrollmentPolicy: "open",
			visibility: "public",
		});

		const freeInput = mutateMock.mock.calls[1][0].variables as Record<string, unknown>;
		expect(freeInput.input).not.toHaveProperty("pricingEnabled");
		expect(freeInput.input).not.toHaveProperty("priceTiers");
	});

	it("F15：UPDATE_EVENT/UPDATE_COURSE 的 result selection 含 pricingEnabled/priceTiers（mutation 文本断言，防 UI 回退旧态）", () => {
		for (const doc of [UPDATE_EVENT, UPDATE_COURSE]) {
			const text = (doc as unknown as { loc: { source: { body: string } } }).loc.source.body;
			expect(text).toContain("pricingEnabled");
			expect(text).toContain("priceTiers");
		}

		// CREATE 同理（详情页跳转前已知收费态）
		for (const doc of [CREATE_EVENT, CREATE_COURSE]) {
			const text = (doc as unknown as { loc: { source: { body: string } } }).loc.source.body;
			expect(text).toContain("pricingEnabled");
			expect(text).toContain("priceTiers");
		}
	});
});

describe("updateOffering input 组装（部分更新语义：未传不落键）", () => {
	it("未传 startsAt/endsAt/venue → 不落键（保留既有值），其余键原样透传", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(mutation).toBe(UPDATE_EVENT);
			expect(variables).toEqual({
				id: "off-1",
				input: { visibility: "workspace" },
			});
			return Promise.resolve(ok("updateEvent"));
		});

		await updateOffering("off-1", "event", { visibility: "workspace" });
	});

	it("event：显式传值 → startsAt/endsAt 透传 ISO、venue 草稿组 JsonString 落键", async () => {
		mutateMock.mockImplementation(({ variables }) => {
			const input = (variables as { input: Record<string, unknown> }).input;
			expect(input).toEqual({
				startsAt: "2026-09-01T01:30:00.000Z",
				endsAt: "2026-09-01T04:00:00.000Z",
				venue: JSON.stringify({
					country: "中国",
					province: "浙江省",
					city: "杭州市",
					district: "西湖区",
				}),
			});
			return Promise.resolve(ok("updateEvent"));
		});

		await updateOffering("off-1", "event", {
			startsAt: "2026-09-01T01:30:00.000Z",
			endsAt: "2026-09-01T04:00:00.000Z",
			venue: {
				country: "中国",
				province: "浙江省",
				city: "杭州市",
				district: "西湖区",
			},
		});
	});

	it("event：venue 显式 null 或全空草稿 → null 落键（清除既有 venue）", async () => {
		mutateMock.mockImplementation(({ variables }) => {
			const input = (variables as { input: Record<string, unknown> }).input;
			expect(input.venue).toBeNull();
			return Promise.resolve(ok("updateEvent"));
		});

		await updateOffering("off-1", "event", { venue: null });
		await updateOffering("off-1", "event", {
			venue: { country: "", province: "", city: "", district: "" },
		});
		expect(mutateMock).toHaveBeenCalledTimes(2);
	});

	it("course：误传 venue 也剥离不下发（schema 无 venue 字段）", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			const input = (variables as { input: Record<string, unknown> }).input;
			expect(mutation).toBe(UPDATE_COURSE);
			expect(input).not.toHaveProperty("venue");
			return Promise.resolve(ok("updateCourse"));
		});

		await updateOffering("off-1", "course", {
			venue: { country: "", province: "", city: "", district: "" },
		});
	});
});

describe("formatDeadline locale（F7：/en 页面日期随 locale 派生）", () => {
	const D = "2026-08-25T14:00:00+08:00";
	const OPTS = {
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
	} as const;

	it("缺省 locale 保持 zh-CN（既有调用点行为不变）", () => {
		// Node ICU 的具体形状随环境（本机 zh-CN → 2026/08/25 14:00），断言锚定
		// 「缺省 = zh-CN 同参派生」而非固定字符串
		expect(formatDeadline(D, "未定")).toBe(
			new Date(D).toLocaleString("zh-CN", OPTS),
		);
	});

	it("locale 透传：en → en 形状（如 08/25/2026, 02:00 PM），与缺省 zh-CN 输出不同", () => {
		const en = formatDeadline(D, "TBD", "en");
		expect(en).toBe(new Date(D).toLocaleString("en", OPTS));
		expect(en).not.toBe(formatDeadline(D, "TBD"));
	});

	it("null/非法值 → undecidedLabel（与 locale 无关）", () => {
		expect(formatDeadline(null, "未定", "en")).toBe("未定");
		expect(formatDeadline("not-a-date", "未定", "en")).toBe("未定");
	});
});
