import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";

/**
 * 设计 token 守卫（plan 004）。
 *
 * 防止多 agent 并行改 CSS 时的常见腐化：dark/light token 不对称、@theme 桥接引用了
 * :root 未定义的 var、关键品牌值被无意改色。纯文本解析 globals.css 断言，对标 backend
 * rbac_contract.json golden-file 守卫思路。权威实现源 = web/app/globals.css。
 *
 * 新增 token 时若加 dark 必加 light（A 拦），并在 @theme 桥接（B 拦）；关键品牌值变更
 * 先改 DESIGN.md + globals.css 再更新此处 golden（C/D 拦）——顺序错测试红正是它的职责。
 */
// vitest 转换后 import.meta.url 非 file: scheme，用 import.meta.dirname（文件相对、不依赖 cwd）
const css = fs.readFileSync(
  path.resolve(import.meta.dirname, "../app/globals.css"),
  "utf8",
);

/** 定位选择器（:root / .light / @theme）后第一个 {...} 的块体，按花括号深度配对。 */
function extractBlock(source: string, selector: string): string | null {
  const esc = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(esc + "\\s*\\{");
  const m = re.exec(source);
  if (!m) return null;
  let depth = 0;
  for (let i = m.index; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}") {
      depth--;
      if (depth === 0) return source.slice(source.indexOf("{", m.index) + 1, i);
    }
  }
  return null;
}

/** 从块体提取 token → rawValue（去掉行内 /* 注释 *\/ 与首尾空白）。 */
function parseTokens(block: string): Map<string, string> {
  const tokens = new Map<string, string>();
  const re = /--([\w-]+)\s*:\s*([^;]+);/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(block)) !== null) {
    tokens.set(m[1], m[2].replace(/\/\*[\s\S]*?\*\//g, "").trim());
  }
  return tokens;
}

const darkBlock = extractBlock(css, ":root");
const lightBlock = extractBlock(css, ".light");
const themeBlock = extractBlock(css, "@theme");

if (!darkBlock || !lightBlock || !themeBlock) {
  throw new Error(
    "无法定位 :root / .light / @theme 块——globals.css 结构已变，复核 design-tokens 守卫解析。",
  );
}

const darkTokens = parseTokens(darkBlock);
const lightTokens = parseTokens(lightBlock);

describe("设计 token 守卫", () => {
  it("A. dark :root 与 light .light 的 color-token key 完全对称", () => {
    expect(lightTokens.size).toBeGreaterThan(0);
    const missingInLight = [...darkTokens.keys()].filter(
      (k) => !lightTokens.has(k),
    );
    const missingInDark = [...lightTokens.keys()].filter(
      (k) => !darkTokens.has(k),
    );
    expect(
      { missingInLight, missingInDark },
      `两主题 color token 不对称：dark 缺 ${JSON.stringify(missingInDark)}，light 缺 ${JSON.stringify(missingInLight)}`,
    ).toEqual({ missingInLight: [], missingInDark: [] });
  });

  it("B. @theme 的 --color-* 桥接映射，其 var(--xxx) 都在 :root 有定义", () => {
    // 只查 color 桥接（--color-X: var(--Y)）；var(--font-inter) 等是 next/font 运行时
    // 注入、不在 globals.css :root 定义，不属于颜色桥接完整性范畴。
    const refs = [
      ...themeBlock.matchAll(/--color-[\w-]+\s*:\s*var\(--([\w-]+)\)/g),
    ].map((m) => m[1]);
    expect(refs.length).toBeGreaterThan(0);
    const dangling = refs.filter((r) => !darkTokens.has(r));
    expect(
      dangling,
      `@theme color 桥接引用了 :root 未定义的 token：${dangling.join(", ")}`,
    ).toEqual([]);
  });

  it("C. dark 关键 golden 值未被改动", () => {
    expect(darkTokens.get("accent")).toBe("#ea5504");
    expect(darkTokens.get("canvas")).toBe("#08090a");
    expect(darkTokens.get("line")).toBe("rgba(255, 255, 255, 0.08)");
  });

  it("D. 品牌色 --accent 两主题一致（均 #ea5504，CGC 品牌橙）", () => {
    expect(darkTokens.get("accent")).toBe("#ea5504");
    expect(lightTokens.get("accent")).toBe("#ea5504");
  });

  it("E. .ld-root 固定深色门面：landing/详情仍重声明暗色 token", () => {
    const ldBlock = extractBlock(css, ".ld-root");
    expect(ldBlock, "无法定位 .ld-root 块——landing/详情固定深色门面被移除？").not.toBeNull();
    const ldTokens = parseTokens(ldBlock!);
    expect(ldTokens.get("canvas")).toBe("#08090a");
    expect(ldTokens.get("ink")).toBe("#f7f8f8");
    expect(ldBlock).toContain("background: var(--canvas)");
    expect(ldBlock).toContain("min-height: 100svh");
  });

  it("F. .public-catalog 跟随全局主题 token，不重声明固定暗色值", () => {
    const catalogBlock = extractBlock(css, ".public-catalog");
    expect(catalogBlock, "无法定位 .public-catalog 方向 B 根样式").not.toBeNull();
    expect(parseTokens(catalogBlock!).size).toBe(0);
    expect(catalogBlock).toContain("background: var(--canvas)");
    expect(catalogBlock).toContain("color: var(--ink)");
    expect(catalogBlock).toContain("min-height: 100svh");
  });
});

describe("公开页键盘焦点环规则（F6 补全）", () => {
  it("G. .ld-root :focus-visible 覆盖原生表单控件 input/select/textarea", () => {
    // F6：公开报名/赞助面原生控件（详情邀请码 input、价格 radio、赞助意向表单
    // select/input）必须被 .ld-root 作用域的焦点环规则覆盖。组件测试环境
    // （happy-dom）不加载 globals.css，computed outline 不可断言——由本规则
    // 文本守卫 + 详情页测试的结构断言（控件位于 main.ld-root 内）共同覆盖。
    const rule =
      /\.ld-root a:focus-visible,[\s\S]*\.ld-root input:focus-visible,[\s\S]*\.ld-root select:focus-visible,[\s\S]*\.ld-root textarea:focus-visible,[\s\S]*outline: 2px solid var\(--accent-strong\);[\s\S]*outline-offset: 2px;/.exec(
        css,
      );
    expect(rule).not.toBeNull();
  });
});
