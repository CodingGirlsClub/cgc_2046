import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { cleanup, screen, within } from "@testing-library/react";
import { render } from "@/test-utils";
import HackerStart1024Page from "@/components/hackerstart-1024/campaign-page";
import { richTags } from "@/components/hackerstart-1024/pow";
import zhCN from "@/messages/zh-CN.json";
import en from "@/messages/en.json";
import { generateMetadata } from "./page";

/**
 * /hackerstart-1024 宣传页测试（U6：R1-R7、R17、R18；Covers AE6、AE7、F1、F3）。
 *
 * 确定性分层：结构 / 文案 / 口径 / SEO 全走断言（能数值断言的不问模型）；
 * ≤640px 的真实几何（无横向滚动、序号与标题同行）由浏览器侧走查承担，
 * 这里锁 CSS 契约与消息契约（漏一处即红）。
 */

const CAMPAIGN_PATH = "/hackerstart-1024";
/** 志愿者申请页（U7 路由，R3/R10 的志愿者入口落点） */
const VOLUNTEER_PATH = `${CAMPAIGN_PATH}/volunteer`;

// ThemeProvider / next-intl 导航依赖 pathname（与 landing-page.test.tsx 同款桩）
vi.mock("next/navigation", () => ({
	usePathname: () => CAMPAIGN_PATH,
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	useParams: () => ({}),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

// generateMetadata 是 server 侧 API：在测试里用真实 messages 复刻 getTranslations
// 的取词行为（canonical/hreflang 与分享 meta 都必须落在真实文案上）。
vi.mock("next-intl/server", () => ({
	getTranslations: async ({
		locale,
		namespace,
	}: {
		locale: string;
		namespace?: string;
	}) => {
		const messages = (
			locale === "en"
				? await import("@/messages/en.json")
				: await import("@/messages/zh-CN.json")
		).default as Record<string, unknown>;
		const scope = (namespace ?? "")
			.split(".")
			.filter(Boolean)
			.reduce<unknown>(
				(node, key) => (node as Record<string, unknown> | undefined)?.[key],
				messages,
			);
		return (key: string) => (scope as Record<string, string> | undefined)?.[key];
	},
}));

const ZH = zhCN.hackerstart1024;
const EN = en.hackerstart1024;

/** 页面渲染覆盖的源码（口径 grep 的代码侧；exclude 测试与原型目录） */
const SOURCE_FILES = [
	"../../../components/hackerstart-1024/campaign-page.tsx",
	"../../../components/hackerstart-1024/hero.tsx",
	"../../../components/hackerstart-1024/participant-sections.tsx",
	"../../../components/hackerstart-1024/volunteer-sections.tsx",
	"../../../components/hackerstart-1024/brand-sections.tsx",
	"../../../components/hackerstart-1024/pow.tsx",
	"./page.tsx",
];

const CAMPAIGN_CSS = "../../../components/hackerstart-1024/hackerstart-1024.css";

function readSource(relativePath: string): string {
	return readFileSync(
		fileURLToPath(new URL(relativePath, import.meta.url)),
		"utf8",
	);
}

/**
 * 消息 → 渲染后的可见文本：富文本标签去掉，幂标记补回被 Pow 组件拆开的 2
 * （`<pow>10</pow>` 渲染成 2<sup>10</sup>，textContent 是 "210"）。
 * 顺带成为「消息与渲染一致」的断言基准。
 */
function plain(message: string): string {
	return message
		.replace(/<pow>(\d+)<\/pow>/g, "2$1")
		.replace(/<\/?[a-z]+>/g, "");
}

/** 按选择器取节点文本（含行内标记的段落 getByText 只匹配直接文本子节点） */
function textOf(selector: string): string {
	const node = document.querySelector(selector);
	expect(node, `缺少节点 ${selector}`).not.toBeNull();
	return node?.textContent ?? "";
}

/** 递归展开嵌套对象为点路径键集合（数组按叶子处理） */
function flattenKeys(node: unknown, prefix = ""): string[] {
	if (node === null || typeof node !== "object" || Array.isArray(node)) {
		return [prefix];
	}
	return Object.entries(node as Record<string, unknown>).flatMap(([key, value]) =>
		flattenKeys(value, prefix ? `${prefix}.${key}` : key),
	);
}

/** 展开消息为 [点路径, 字符串] 列表：口径 grep 要按条目定位，而不是整份 JSON 一行 */
function messageEntries(node: unknown, prefix = ""): Array<[string, string]> {
	if (typeof node === "string") return [[prefix, node]];
	if (Array.isArray(node)) {
		return node.flatMap((item, index) =>
			messageEntries(item, `${prefix}[${index}]`),
		);
	}
	if (node !== null && typeof node === "object") {
		return Object.entries(node as Record<string, unknown>).flatMap(([key, value]) =>
			messageEntries(value, prefix ? `${prefix}.${key}` : key),
		);
	}
	return [];
}

afterEach(cleanup);

describe("/hackerstart-1024 宣传页（U6）", () => {
	it("九段 IA：hero + 七段标题 + 留存位 + footer，顺序与 R2 一致", () => {
		render(<HackerStart1024Page />);

		// 各段标题 = 消息原文（含 <em> 玫红段与 <pow> 幂标记的渲染结果）
		const titles: Array<[string, string, "H1" | "H2"]> = [
			["#hs24-hero-title", ZH.hero.title, "H1"],
			["#hs24-why-title", ZH.why.title, "H2"],
			["#hs24-join-title", ZH.join.title, "H2"],
			["#hs24-faq-title", ZH.faq.title, "H2"],
			["#hs24-volunteer-title", ZH.volunteer.title, "H2"],
			["#hs24-timeline-title", ZH.timeline.title, "H2"],
			["#hs24-who-title", ZH.who.title, "H2"],
			["#hs24-brand-title", ZH.brand.title, "H2"],
		];
		for (const [selector, message, tag] of titles) {
			const node = document.querySelector(selector);
			expect(node?.tagName, selector).toBe(tag);
			expect(node?.textContent, selector).toBe(plain(message));
		}
		expect(document.querySelectorAll("h1")).toHaveLength(1);

		// 段落顺序（DOM 顺序 = IA 顺序）：hero 自成一段，②-⑧ + 留存位共 8 段
		const sections = Array.from(document.querySelectorAll(".hs24-section"));
		expect(sections).toHaveLength(8);
		expect(document.querySelector("#hs24-join")).toBe(sections[1]);
		expect(document.querySelector("#hs24-volunteer")).toBe(sections[3]);
		expect(document.querySelector("#hs24-brand")).toBe(sections[6]);
		// footer 收尾
		expect(document.querySelector(".hs24-footer")).not.toBeNull();
	});

	it("hero：三入口锚点、刻度条 aria、2¹⁰＝1,024 钩子句", () => {
		render(<HackerStart1024Page />);

		// 三入口按 F1/F2/F3「先读再走」锚到页内段落，锚点目标必须存在
		for (const [label, anchor] of [
			["我要参加", "#hs24-join"],
			["成为志愿者", "#hs24-volunteer"],
			["品牌合作", "#hs24-brand"],
		] as const) {
			const link = screen.getByRole("link", { name: label });
			expect(link).toHaveAttribute("href", anchor);
			expect(document.querySelector(anchor)).not.toBeNull();
		}

		expect(
			screen.getByRole("img", {
				name: "2016 年成立，十年积累，2026 年启动 1,024 场",
			}),
		).toBeInTheDocument();
		// 刻度条两端：2016 成立 / 2026 · 2¹⁰＝1,024 场
		expect(screen.getByText("2016 · 成立")).toBeInTheDocument();
		expect(screen.getByText("第 10 年")).toBeInTheDocument();
		expect(
			textOf(".hs24-scale__tick--end"),
		).toBe(plain(ZH.hero.scaleEnd));
		// 首屏钩子句：2016 成立 → 第 10 年 → 2¹⁰＝1,024 场
		expect(textOf(".hs24-hero-hook")).toBe(plain(ZH.hero.hook));
		// 关键数字行三条（各自带幂标记）
		expect(
			Array.from(document.querySelectorAll(".hs24-hero__nums > span")).map(
				(node) => node.textContent,
			),
		).toEqual([
			plain(ZH.hero.nums.sessions),
			plain(ZH.hero.nums.start),
			plain(ZH.hero.nums.seats),
		]);
	});

	it("R4：关键数字沿 2 的幂标注，幂标记统一样式（所有数字上标都在 .hs24-pow 内）", () => {
		render(<HackerStart1024Page />);

		const powSupers = Array.from(document.querySelectorAll(".hs24-pow sup"));
		const exponents = powSupers.map((node) => node.textContent ?? "");
		// 2⁰（启动日）/ 2³ / 2⁴ / 2⁵ / 2⁶ / 2⁷ / 2¹⁰ —— 与 R4 列举逐一对应
		expect([...new Set(exponents)].sort()).toEqual([
			"0",
			"10",
			"3",
			"4",
			"5",
			"6",
			"7",
		]);

		// 纯数字上标 = 幂标记，一个不少也一个不多（节奏卡的 min 是单位、不受此约束）
		const numericSupers = Array.from(document.querySelectorAll("sup")).filter(
			(node) => /^\d+$/.test(node.textContent ?? ""),
		);
		expect(numericSupers).toHaveLength(powSupers.length);
	});

	it("R4：幂标记渲染数 = 消息里 <pow> 出现次数（漏传 richTags 或漏渲染即红）", () => {
		render(<HackerStart1024Page />);

		const occurrences = JSON.stringify(ZH).match(/<pow>/g)?.length ?? 0;
		expect(occurrences).toBeGreaterThan(0);
		// 幂标记两个来源：消息里的 <pow> 标签（富文本）+ 64 场公式行的 3 个 <Pow>
		// （结构化字段，value/pow 分列，不经富文本）
		expect(document.querySelectorAll(".hs24-pow")).toHaveLength(occurrences + 3);

		// 富文本标签全在 richTags 登记（漏登记会把字面量 <tag> 漏到页面上）
		const tags = new Set(
			Array.from(JSON.stringify(ZH).matchAll(/<([a-z][a-z0-9]*)>/g)).map(
				(match) => match[1],
			),
		);
		for (const tag of tags) {
			expect(Object.keys(richTags)).toContain(tag);
		}
		expect(document.body.textContent).not.toMatch(/<[a-z]+>/);
	});

	it("R4 口径纪律：消息与页面源码无厂商名、无价格数字（AE7 前置）", () => {
		const source = SOURCE_FILES.map(readSource).join("\n");
		const haystack = `${JSON.stringify(ZH)}\n${JSON.stringify(EN)}\n${source}`;

		// 厂商名（含 OpenClacky）：本页对所有 AI 工具厂商保持中立
		for (const vendor of [
			"OpenClacky",
			"Clacky",
			"Claude",
			"Anthropic",
			"OpenAI",
			"ChatGPT",
			"Gemini",
			"Copilot",
			"Cursor",
			"DeepSeek",
			"Codex",
			"TRAE",
			"Kimi",
			"Qwen",
			"通义",
			"豆包",
			"文心",
			"智谱",
			"Windsurf",
		]) {
			expect(haystack).not.toContain(vendor);
		}

		// 商务价格（合作费用 / 加购项等商务条款）零命中：押金金额另例放行
		// （见「押金口径」例——押金是参与者行动的必要信息，不属于商务条款价格）
		expect(haystack).not.toMatch(/[¥￥]/);
		expect(haystack).not.toMatch(/\d+\s*(RMB|CNY|USD|EUR)/i);
		// 「8-15 万」类商务报价；历史累计的「2,000 万+」总阅读量不是价格，负向断言排除
		expect(haystack).not.toMatch(/\d+\s*万(?!\s*\+)/);
	});

	it("R4 押金口径：69 元押金四处告知，且只出现在押金语境（zh/en 同步）", () => {
		render(<HackerStart1024Page />);

		// ① why 段 lead（原型口径：69 元押金（到场退））
		const whySection = document.querySelector("#hs24-why-title")?.closest("section");
		expect(whySection).not.toBeNull();
		expect(
			(whySection as HTMLElement).querySelector(".hs24-lead")?.textContent,
		).toContain("69 元押金（到场退）");
		// ② 参与者 FAQ：问句与答案都含金额与退法
		expect(screen.getByText("69 元押金是怎么回事？怎么退？")).toBeInTheDocument();
		expect(screen.getByText(/报名时缴纳 69 元押金/)).toBeInTheDocument();
		// ③ 价值阶梯「激活用户」层
		expect(
			Array.from(document.querySelectorAll(".hs24-ladder__d")).some((node) =>
				/18 岁以上、付 69 元押金/.test(node.textContent ?? ""),
			),
		).toBe(true);

		// 消息侧（zh）：金额只允许出现在这四个条目，且每条都必须带「押金」
		const zhEntries = messageEntries(ZH);
		const amountEntries = zhEntries.filter(([, value]) => /\d+\s*元/.test(value));
		expect(amountEntries.map(([key]) => key).sort()).toEqual([
			"brand.ladder[1].d",
			"faq.items[1].a",
			"faq.items[1].q",
			"why.lead",
		]);
		for (const [key, value] of amountEntries) {
			expect(value, key).toContain("押金");
		}

		// 消息侧（en）：镜像同一条纪律——出现 69 的条目必须同时含 deposit
		const enAmountEntries = messageEntries(EN).filter(([, value]) =>
			/69/.test(value),
		);
		expect(enAmountEntries.map(([key]) => key).sort()).toEqual([
			"brand.ladder[1].d",
			"faq.items[1].a",
			"faq.items[1].q",
			"why.lead",
		]);
		for (const [key, value] of enAmountEntries) {
			expect(value, key).toMatch(/deposit/i);
		}
	});

	it("R4/AE7：历史累计只出现在历史带内，本轮计划数字都带「本轮」标注", () => {
		render(<HackerStart1024Page />);

		// 历史侧：十年数字带整体标注 2016-2025 历史累计，带内不含本轮/2026.10-2027
		const historyBand = document.querySelector(".hs24-stats");
		expect(historyBand).not.toBeNull();
		expect(within(historyBand as HTMLElement).getByText("4,000+")).toBeInTheDocument();
		expect(within(historyBand as HTMLElement).getByText("2,000 万+")).toBeInTheDocument();
		expect(historyBand?.textContent).not.toMatch(/本轮|2026\.10-2027/);
		expect(textOf(".hs24-stats__cap")).toBe("2016-2025 历史累计");

		// 本轮侧：凡是出现本轮计划数字的段落，都必须带「本轮」标注
		const planParagraphs = Array.from(document.querySelectorAll("p")).filter(
			(node) => /512-2,048/.test(node.textContent ?? ""),
		);
		expect(planParagraphs.length).toBeGreaterThan(0);
		for (const node of planParagraphs) {
			expect(node.textContent).toMatch(/本轮/);
		}
		expect(textOf(".hs24-plan-cap")).toBe(ZH.brand.planCap);
		expect(textOf(".hs24-plan-cap")).toContain("本轮计划");

		// 两口径的对照句单列（杠杆句），避免被读成本轮数字
		expect(textOf(".hs24-lever")).toBe(
			"本轮一个 campaign 的参与人数目标 ≈ 过去十年累计",
		);
		// 历史累计在阶梯里也必须自带标注，不能裸用
		expect(screen.getByText(/历史总阅读 2,000 万\+，历史累计/)).toBeInTheDocument();
	});

	it("R5：证据墙 7 条外链 href 与列举一致，共青团中央与果壳网保留文字不挂链", () => {
		render(<HackerStart1024Page />);

		const whoSection = document
			.querySelector("#hs24-who-title")
			?.closest("section");
		expect(whoSection).not.toBeNull();
		const wall = within(whoSection as HTMLElement);

		expect(wall.getAllByRole("link").map((link) => link.getAttribute("href"))).toEqual([
			"https://cmustrudel.github.io/papers/chase21code_camps.pdf",
			"https://www.undp.org/zh/china/publications/kejiyucishankechixufazhanxingdongbaogao",
			"https://www.linkedin.com/posts/undp-china_herstory-womenintech-%E7%A7%91%E6%8A%80%E9%81%87%E8%A7%81%E5%A5%B9-activity-6787232105513525248-w6vp",
			"https://www.chinadaily.com.cn/china/2017-01/13/content_27943492.htm",
			"https://www.globaltimes.cn/content/954372.shtml",
			"https://news.cgtn.com/news/3d49544e31516a4d/share_p.html",
			"https://mp.weixin.qq.com/s/IfRSC8sA7THv-YPBa4_XAg",
		]);
		for (const link of wall.getAllByRole("link")) {
			expect(link).toHaveAttribute("target", "_blank");
			expect(link).toHaveAttribute("rel", "noopener noreferrer");
		}

		// 无稳定链接的两条只保留文字
		expect(wall.getByText("共青团中央「伙伴计划」获奖")).toBeInTheDocument();
		expect(wall.getByText("果壳网")).toBeInTheDocument();
		expect(wall.queryByRole("link", { name: /共青团中央/ })).toBeNull();
		expect(wall.queryByRole("link", { name: /果壳/ })).toBeNull();
		// 学员故事：链接已挂、标题待补（R5）
		expect(wall.getByRole("link", { name: /学员的故事/ })).toBeInTheDocument();
	});

	it("R3：三入口落点（我要参加 → /initiatives、成为志愿者 → 申请页、品牌合作 → mailto）", () => {
		render(<HackerStart1024Page />);

		expect(
			screen.getByRole("link", { name: "报名通道 2026.10.24 起陆续开放 →" }),
		).toHaveAttribute("href", "/initiatives");
		expect(
			screen.getByRole("link", { name: "申请成为志愿者 →" }),
		).toHaveAttribute("href", VOLUNTEER_PATH);
		expect(
			screen.getByRole("link", { name: /聊品牌专场合作/ }),
		).toHaveAttribute("href", "mailto:partners@codinggirlsclub.com");
		// footer 志愿者回链走页内锚点（F2 先读职位与流程）
		expect(
			screen.getByRole("link", { name: /来成为志愿者/ }),
		).toHaveAttribute("href", "#hs24-volunteer");
	});

	it("R2：批次卡静态「首批招募进行中」，不写死日期", () => {
		render(<HackerStart1024Page />);

		const cohort = document.querySelector(".hs24-cohort");
		expect(cohort).not.toBeNull();
		expect(cohort?.textContent).toContain("进行中");
		expect(cohort?.textContent).toContain("首批招募进行中");
		// 批次卡不得出现任何写死日期（真实状态由申请页动态承载）
		expect(cohort?.textContent).not.toMatch(
			/\d{4}\s*[.\-/年]\s*\d{1,2}|\d{1,2}\s*月\s*\d{1,2}\s*日/,
		);

		// 三职位小卡：featured 是场次主理人（首批最需要）
		const volunteerSection = document.querySelector("#hs24-volunteer");
		expect(volunteerSection).not.toBeNull();
		const roles = Array.from(
			(volunteerSection as HTMLElement).querySelectorAll(".hs24-cap3 .hs24-tile"),
		);
		expect(roles).toHaveLength(3);
		expect(roles[0]?.textContent).toContain("场次主理人");
		expect(roles[0]?.textContent).toContain("Event Moderator");
		expect(roles[0]?.textContent).toContain("首批最需要");
		expect(roles[0]?.className).toContain("hs24-tile--featured");
		expect(roles[1]?.textContent).toContain("教程研究员");
		expect(roles[2]?.textContent).toContain("活动教练");
	});

	it("R17：时间线三节点（启动 → 首期 64 场 → 批次滚动至 1,024 场）", () => {
		render(<HackerStart1024Page />);

		const nodes = Array.from(document.querySelectorAll(".hs24-timeline .hs24-tl__item"));
		expect(nodes).toHaveLength(3);
		expect(nodes[0]?.className).toContain("hs24-tl__item--start");
		expect(nodes[0]?.textContent).toContain("2026.10.24 启动");
		expect(nodes[1]?.textContent).toContain("首期 64 场");
		expect(nodes[2]?.textContent).toContain("批次滚动");
		expect(nodes[2]?.textContent).toContain("1,024 场");
	});

	it("参与者 FAQ：5 条问答，含押金问答（金额按整合复核恢复）", () => {
		render(<HackerStart1024Page />);

		const details = Array.from(document.querySelectorAll(".hs24-faq details"));
		expect(details).toHaveLength(5);
		expect(screen.getByText("69 元押金是怎么回事？怎么退？")).toBeInTheDocument();
		expect(screen.getByText(/到场参加即全额退还/)).toBeInTheDocument();
		expect(screen.getByText(/零基础真的能参加吗？/)).toBeInTheDocument();
	});

	it("i18n：zh/en 键集与数组条目一一对应，en 为英文文案（无中文残留）", () => {
		expect(flattenKeys(ZH).sort()).toEqual(flattenKeys(EN).sort());

		// 数组条目数必须一致（少一条 FAQ / 少一个职位 / 少一条背书都算缺覆盖）
		const parallelArrays = (
			zhNode: unknown,
			enNode: unknown,
			path: string,
		): void => {
			if (Array.isArray(zhNode)) {
				expect(Array.isArray(enNode), `${path} 应为数组`).toBe(true);
				expect((enNode as unknown[]).length, `${path} 条目数`).toBe(zhNode.length);
				return;
			}
			if (zhNode !== null && typeof zhNode === "object") {
				for (const [key, value] of Object.entries(zhNode as Record<string, unknown>)) {
					parallelArrays(
						value,
						(enNode as Record<string, unknown>)[key],
						`${path}.${key}`,
					);
				}
			}
		};
		parallelArrays(ZH, EN, "hackerstart1024");

		expect(ZH.faq.items).toHaveLength(5);
		expect(ZH.who.stats).toHaveLength(6);
		expect(ZH.who.endorse).toHaveLength(9);
		expect(ZH.brand.ladder).toHaveLength(6);

		// en 侧零中文（人工译文，不是 zh 直出）
		expect(JSON.stringify(EN)).not.toMatch(/[\u4e00-\u9fff]/);
		// 口径纪律句两语言都要正确标注
		expect(EN.who.statsCap).toMatch(/Historical/i);
		expect(EN.who.statsCap).toContain("2016–2025");
		expect(EN.brand.planCap).toMatch(/this round's plan/i);
		expect(EN.brand.ladder[1]?.d).toMatch(/this round's plan/i);
	});

	it("en：整页渲染英文文案（含 hero / 品牌段 / 证据墙）", () => {
		render(<HackerStart1024Page />, { locale: "en" });

		expect(
			screen.getByRole("heading", { level: 1, name: "Hacker Start 1024" }),
		).toBeInTheDocument();
		expect(textOf("#hs24-why-title")).toBe(plain(EN.why.title));
		expect(
			screen.getByRole("link", { name: "Join a session" }),
		).toHaveAttribute("href", "#hs24-join");
		expect(screen.getByText("Historical: cumulative to 2025 (2016–2025)")).toBeInTheDocument();
		expect(screen.getByText(/All figures above are this round's plan/)).toBeInTheDocument();
		// 押金金额 en 侧同样告知（人工译文，非 zh 直出）
		expect(screen.getByText("How does the 69 yuan deposit work?")).toBeInTheDocument();
		expect(screen.getByText(/You pay a 69 yuan deposit when you register/)).toBeInTheDocument();

		// 页面主体（不含顶导的语言切换器，那里本来就并排显示「中文」）零中文
		const campaignText = Array.from(
			document.querySelectorAll(".hs24-hero, .hs24-section, .hs24-footer"),
		)
			.map((node) => node.textContent)
			.join("");
		expect(campaignText).not.toMatch(/[\u4e00-\u9fff]/);
	});

	it("R1/R6：metadata 输出 canonical/hreflang 与分享 meta（分享卡图待补，故意不输出 images）", async () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codinggirlsclub.com");

		const zhMeta = await generateMetadata({
			params: Promise.resolve({ locale: "zh-CN" }),
		});
		expect(zhMeta.alternates).toEqual({
			canonical: "https://codinggirlsclub.com/hackerstart-1024",
			languages: {
				"zh-CN": "https://codinggirlsclub.com/hackerstart-1024",
				en: "https://codinggirlsclub.com/en/hackerstart-1024",
			},
		});
		expect(zhMeta.title).toBe(ZH.meta.title);
		expect(zhMeta.description).toBe(ZH.meta.description);
		expect(zhMeta.openGraph?.title).toBe(ZH.meta.title);
		expect(zhMeta.openGraph?.description).toBe(ZH.meta.description);
		expect(zhMeta.openGraph?.url).toBe(
			"https://codinggirlsclub.com/hackerstart-1024",
		);
		// 分享卡图素材未就绪：images 缺席（补齐后此断言改成图片 URL）
		expect(zhMeta.openGraph?.images).toBeUndefined();

		const enMeta = await generateMetadata({
			params: Promise.resolve({ locale: "en" }),
		});
		expect(enMeta.alternates?.canonical).toBe(
			"https://codinggirlsclub.com/en/hackerstart-1024",
		);
		expect(enMeta.title).toBe(EN.meta.title);
		expect(enMeta.description).toBe(EN.meta.description);

		vi.unstubAllEnvs();
	});

	it("留存位：公众号二维码真实素材（alt + 资源存在）", async () => {
		render(<HackerStart1024Page />);
		const qr = screen.getByAltText(zhCN.hackerstart1024.follow.qr);
		expect(qr).toHaveAttribute("src", "/hackerstart-1024/cgc-wechat-qr-430.jpg");
	});

	it("错误路径：messages 缺 namespace 时不白屏（next-intl 回落 key 路径）", () => {
		// 部署侧 messages 失配（命名空间整段缺失）时页面必须照常渲染骨架，
		// 而不是 500——真实缺口由上面的键集/数组/标签守卫负责拦截。
		const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
		try {
			render(<HackerStart1024Page />, {
				messages: { hackerstart1024: { meta: {} } },
			});
			expect(document.querySelectorAll(".hs24-section")).toHaveLength(8);
			// 回落成完整 key 路径（可定位），列表段落回落空数组而非崩掉
			expect(textOf("#hs24-who-title")).toBe("hackerstart1024.who.title");
			expect(document.querySelectorAll(".hs24-stats .hs24-stat")).toHaveLength(0);
			expect(document.querySelectorAll(".hs24-faq details")).toHaveLength(0);
		} finally {
			consoleError.mockRestore();
		}
	});

	it("R18/CSS 契约：≤640px 单列化、序号与标题同行、hero 关键数字单行、PPT 色板", () => {
		const css = readSource(CAMPAIGN_CSS);
		const lower = css.toLowerCase();

		for (const color of [
			"#c9497d",
			"#b0406b",
			"#2b2b33",
			"#857f8f",
			"#b9b3c2",
			"#e8e4ec",
			"#faedf2",
			"#e7f5f3",
			"#2fa69d",
		]) {
			expect(lower).toContain(color);
		}

		const mobileStart = css.indexOf("@media (max-width: 640px)");
		expect(mobileStart).toBeGreaterThan(-1);
		const mobile = css.slice(mobileStart);
		// 卡片网格单列
		expect(mobile).toMatch(
			/\.hs24-cap3,\s*\.hs24-tiles,\s*\.hs24-openqs\s*\{\s*grid-template-columns:\s*1fr;/,
		);
		// hero 关键数字各自独占一行（不折在短语中间）
		expect(mobile).toMatch(/\.hs24-hero__nums span\s*\{\s*flex:\s*1 1 100%;/);
		// 触屏边距
		expect(mobile).toMatch(/\.hs24-container\s*\{\s*padding:\s*0 18px;/);

		// 横向滚动：section 裁掉装饰圆角的右溢出（原型实测 390px 下多出 34px）
		expect(css).toMatch(/\.hs24-section\s*\{[^}]*overflow-x:\s*clip;/);

		// 字体栈挂在容器上而非页面根：顶导是站级共享组件，不能被本页换字体
		expect(css).toMatch(/\.hs24-container\s*\{[^}]*font-family:\s*"PingFang SC"/);
		expect(css).not.toMatch(/\.hs24-root\s*\{[^}]*font-family:/);

		// 序号徽章与标题同行（所有尺寸）：flex 行 + 徽章不换行、不吃 margin
		expect(css).toMatch(
			/\.hs24-tile__t\s*\{[^}]*display:\s*flex;[^}]*align-items:\s*center;/,
		);
		expect(css).toMatch(
			/\.hs24-tile__t \.hs24-tile__n\s*\{[^}]*margin-bottom:\s*0;[^}]*flex:\s*none;/,
		);
	});
});
