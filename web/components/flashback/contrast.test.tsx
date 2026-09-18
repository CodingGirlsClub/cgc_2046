import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen, waitFor } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { render } from "@/test-utils";
import CardExport from "./card-export";
import RecoverForm from "./recover-form";
import type { FlashbackCapsuleMe } from "@/lib/graphql/flashback";

/**
 * 对比度防回归（两起实测 bug：找回输入框、card-export 按钮组）。
 *
 * 两层防线（happy-dom 不 resolve `color: inherit` 终值，浏览器层
 * cascade 断言在此环境不可靠，故用确定性的组合）：
 *
 * 1. **CSS 源数值断言**：解析 flashback.css，对易碎选择器块断言
 *    (a) color 声明与已知底色的 WCAG 对比度 ≥4.5；
 *    (b) 暗底按钮/输入类的选择器带 `.fb-root ` 前缀（特异性 0-2-0
 *        压过 `.fb-root button { color: inherit }` 0-1-1——两起 bug
 *        的根源即显式色被继承链吞掉成深墨）。
 * 2. **继承链断言**：`.fb-root` 的 computed color 必须是暗底亮字
 *    #d9d4ca（翻转回 --fb-ink 深墨即红——那是第一起 bug 前的默认）。
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const CSS_PATH = resolve(HERE, "../../app/[locale]/flashback/flashback.css");
const css = readFileSync(CSS_PATH, "utf8");

/** WCAG 对比度（与浏览器审计脚本同公式） */
function contrastRatio(hex: string, bg: [number, number, number]): number {
	const rgb = [
		parseInt(hex.slice(1, 3), 16),
		parseInt(hex.slice(3, 5), 16),
		parseInt(hex.slice(5, 7), 16),
	];
	const channel = (v: number) => {
		v /= 255;
		return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
	};
	const lum = 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2]);
	const bl = (bg: number) => {
		const v = bg / 255;
		return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
	};
	const bgLum = 0.2126 * bl(bg[0]) + 0.7152 * bl(bg[1]) + 0.0722 * bl(bg[2]);
	const [hi, lo] = lum > bgLum ? [lum, bgLum] : [bgLum, lum];
	return (hi + 0.05) / (lo + 0.05);
}

/** 抽取选择器块内的 color 声明（首个 #hex 色） */
function declaredColor(selector: string): string | null {
	// 组选择器（逗号后续成员）允许：selector 后可跟 , 其余成员再到 {
	const re = new RegExp(`${selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")},?[^{]*\\{([^}]*)\\}`);
	const m = css.match(re);
	if (!m) return null;
	const hex = m[1].match(/color:\s*(#[0-9a-fA-F]{6})\b/);
	if (hex) return hex[1];
	const varName = m[1].match(/color:\s*var\((--[a-z-]+)\)/);
	return varName ? `var(${varName[1]})` : null;
}

const PAGE_BG: [number, number, number] = [10, 10, 12]; // .fb-root #0a0a0c
const CARD_BG: [number, number, number] = [26, 26, 28]; // 暗卡片 ≈ 0.07 纸 over 页底

// RecoverForm 走 useMutation：本文件主题是样式，mock 掉 Apollo hook
const { useMutationMock } = vi.hoisted(() => ({ useMutationMock: vi.fn(() => [vi.fn(), { loading: false }]) }));
vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return { ...actual, useMutation: useMutationMock };
});

vi.mock("@/i18n/navigation", () => ({
	Link: ({ href, children, ...rest }: { href: string; children: React.ReactNode } & Record<string, unknown>) => (
		<a href={href} {...rest}>{children}</a>
	),
	usePathname: () => "/flashback",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));

let styleEl: HTMLStyleElement;

beforeEach(() => {
	styleEl = document.createElement("style");
	styleEl.textContent = css;
	document.head.appendChild(styleEl);
});

afterEach(() => {
	styleEl.remove();
	cleanup();
});

describe("防线 1：CSS 源对比度数值断言（WCAG ≥4.5:1）", () => {
	it("card-export 按钮组（用户二报）：选择器带 .fb-root 前缀 + 双态色 ≥4.5", () => {
		// 特异性守卫：不带前缀 = 显式色会被 color:inherit（0-1-1）压成深墨（原 bug）
		expect(css).toMatch(/\.fb-root \.fb-export-tab\s*\{/);
		expect(css).toMatch(/\.fb-root \.fb-export-tab--active\s*\{/);

		const idle = declaredColor(".fb-root .fb-export-tab");
		const active = declaredColor(".fb-root .fb-export-tab--active");

		expect(idle, "未选中态须有显式色").toBe("#b9b4aa");
		expect(contrastRatio(idle!, CARD_BG)).toBeGreaterThanOrEqual(4.5);

		expect(active, "选中态须为金色（与描边一致）").toBe("var(--fb-accent)");
		// --fb-accent = #cbbf8f：数值断言其对比度
		expect(contrastRatio("#cbbf8f", CARD_BG)).toBeGreaterThanOrEqual(4.5);
	});

	it("找回/注册输入框（用户一报）：文字与 placeholder 双 ≥4.5", () => {
		expect(css).toMatch(/\.fb-root input\.fb-recover-input\s*,/);

		const text = declaredColor(".fb-root input.fb-recover-input");
		const ph = declaredColor(".fb-root input.fb-recover-input::placeholder");

		expect(text).toBe("#ece8de");
		expect(contrastRatio(text!, PAGE_BG)).toBeGreaterThanOrEqual(4.5);
		expect(ph).toBe("#a09a8f");
		expect(contrastRatio(ph!, PAGE_BG)).toBeGreaterThanOrEqual(4.5);
	});

	it("通用按钮与清扫修复项：fb-cta / fb-option / 删除面板 / 删除确认底色", () => {
		expect(css).toMatch(/\.fb-root \.fb-cta\s*\{/);
		expect(css).toMatch(/\.fb-root \.fb-option\s*\{/);

		const cta = declaredColor(".fb-root .fb-cta");
		expect(cta).toBe("#cfcabf");
		expect(contrastRatio(cta!, CARD_BG)).toBeGreaterThanOrEqual(4.5);

		const option = declaredColor(".fb-root .fb-option");
		expect(option).toBe("#d9d4ca");
		expect(contrastRatio(option!, CARD_BG)).toBeGreaterThanOrEqual(4.5);

		// 删除入口（U10 曾引用不存在的 --fb-ink-soft 变量回落暗灰）
		expect(css).toMatch(/\.fb-root \.fb-delete-open\s*\{/);
		const del = declaredColor(".fb-root .fb-delete-open");
		expect(del).toBe("#a09a8f");
		expect(contrastRatio(del!, PAGE_BG)).toBeGreaterThanOrEqual(4.5);

		// 删除确认钮：白字对底色 ≥4.5（原 #b3261e 为 4.43）
		const m = css.match(/\.fb-delete-submit\s*\{[^}]*background:\s*(#[0-9a-fA-F]{6})/);
		expect(m, "delete-submit 须有显式底色").toBeTruthy();
		const white = "#ffffff";
		expect(contrastRatio(white, [0x9e, 0x1b, 0x15])).toBeGreaterThanOrEqual(4.5);
		expect(m![1].toLowerCase()).toBe("#9e1b15");
	});

	it("fb-cta-primary 金底深字（继承链翻转后仍须显式深字）", () => {
		expect(css).toMatch(/\.fb-root \.fb-cta-primary\s*\{/);
		const color = declaredColor(".fb-root .fb-cta-primary");
		expect(color).toBe("#17161a");
		// 金底 #cbbf8f 上的深字
		expect(contrastRatio(color!, [0xcb, 0xbf, 0x8f])).toBeGreaterThanOrEqual(4.5);
	});
});

describe("防线 2：继承链守卫（.fb-root 默认亮字）", () => {
	it("fb-root computed color = #d9d4ca（翻转回深墨即红——第一起 bug 的默认态）", () => {
		const root = document.createElement("div");
		root.className = "fb-root";
		document.body.appendChild(root);
		expect(getComputedStyle(root).color).toBe("#d9d4ca");
		root.remove();
	});

	it("纸面容器回写 ink（polaroid/write-form/lit 卡）在 CSS 源中声明", () => {
		for (const sel of [".fb-polaroid", ".fb-write-form", ".fb-roster-card--lit", ".fb-export-photo"]) {
			const re = new RegExp(`${sel.replace(".", "\\.")}\\s*\\{[^}]*color:\\s*var\\(--fb-ink\\)`);
			expect(css.match(re), `${sel} 须显式 color: var(--fb-ink)`).toBeTruthy();
		}
	});
});

describe("防线 3：组件行为不回归（card-export 交互冒烟）", () => {
	it("摘要/全文切换仍工作", async () => {
		const me: FlashbackCapsuleMe = {
			id: "p1",
			fullName: "王若愚",
			surname: "王",
			city: "北京",
			occupationThen: null,
			participation: "not_selected",
			appliedAt: null,
			today: null,
			quote: null,
			answers: [{ id: "m1", questionKey: "self_intro", rawText: "一句当年答案。", text: "一句当年答案。" }],
		};
		render(
			<div className="fb-root">
				<CardExport me={me} />
			</div>,
		);

		const full = screen.getByRole("button", { name: "全文卡" });
		full.click();
		await waitFor(() => expect(full.className).toContain("fb-export-tab--active"));
		expect(screen.getByTestId("fb-export-card")).toHaveTextContent("一句当年答案。");
	});

	it("找回表单渲染与输入（发起逻辑由 public-home.test 覆盖）", async () => {
		const { fireEvent } = await import("@testing-library/react");
		render(
			<div className="fb-root">
				<RecoverForm />
			</div>,
		);
		const input = screen.getByLabelText(/当年的手机号或邮箱/);
		fireEvent.change(input, { target: { value: " `a@b.c` " } });
		expect((input as HTMLInputElement).value).toContain("a@b.c");
	});
});
