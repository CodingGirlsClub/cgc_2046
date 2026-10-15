import { render } from "@/test-utils";
import { fireEvent, screen } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { MaterialRenderer } from "./material-renderer";

describe("MaterialRenderer", () => {
  it("escapes HTML while rendering the small markdown subset", () => {
    render(<MaterialRenderer material={{ kind: "markdown", body: "**重点** <script>alert(1)</script>" }} />);
    expect(screen.getByTestId("course-material-markdown").innerHTML).toContain("&lt;script&gt;");
    expect(screen.getByText("重点")).toBeInTheDocument();
    expect(screen.queryByRole("script")).not.toBeInTheDocument();
  });

  it("renders ## / ### headings as h3 / h4 and consecutive dash lines as one ul", () => {
    render(<MaterialRenderer material={{ kind: "markdown", body: "## 章节\n### 小节\n- 第一项\n- 第二项\n正文" }} />);
    const el = screen.getByTestId("course-material-markdown");
    expect(el.querySelector("h3")).toHaveTextContent("章节");
    expect(el.querySelector("h4")).toHaveTextContent("小节");
    const list = el.querySelector("ul");
    expect(list).not.toBeNull();
    expect(list!.querySelectorAll("li")).toHaveLength(2);
    expect(list!).toHaveTextContent("第一项");
    expect(list!).toHaveTextContent("第二项");
    // 列表结束后的正文不再裹进 ul
    expect(el.textContent).toContain("正文");
  });

  it("escapes attribute injection inside headings and list items", () => {
    render(<MaterialRenderer material={{ kind: "markdown", body: "## <img src=x onerror=alert(1)>\n- <b onmouseover=alert(1)>x</b>" }} />);
    const el = screen.getByTestId("course-material-markdown");
    expect(el.querySelector("img")).toBeNull();
    expect(el.querySelector("b")).toBeNull();
    expect(el.innerHTML).toContain("&lt;img");
    expect(el.innerHTML).toContain("&lt;b");
  });

  it("renders a GFM table as a real table inside a scroll container (#1118)", () => {
    const body = [
      "| 流程步骤 | 使用普通 Chat AI | 使用本地 AI Agent |",
      "|---|---|---|",
      "| 1. 准备素材 | 手动找到文件 | 告诉 Agent：「读取当前文件夹下的 xx 文件」|",
      "| 2. 生成内容 | 输出一堆文字 | 理解要求后规划并生成 |",
    ].join("\n");
    render(<MaterialRenderer material={{ kind: "markdown", body }} />);
    const el = screen.getByTestId("course-material-markdown");
    expect(el.querySelectorAll("table")).toHaveLength(1);
    const header = el.querySelectorAll("thead th");
    expect(header).toHaveLength(3);
    expect(header[0]).toHaveTextContent("流程步骤");
    expect(header[2]).toHaveTextContent("使用本地 AI Agent");
    const rows = el.querySelectorAll("tbody tr");
    expect(rows).toHaveLength(2);
    expect(rows[0].querySelectorAll("td")).toHaveLength(3);
    expect(rows[1]).toHaveTextContent("理解要求后规划并生成");
    // 窄栏里靠容器横向滚动，而不是把正文列撑破
    expect(el.querySelector("table")!.closest(".learning-material__table-wrap")).not.toBeNull();
    // 表格语法本身不再作为竖线纯文本漏进正文
    expect(el.textContent).not.toContain("|---|");
  });

  it("strips unsafe link protocols and non-https images (#1118)", () => {
    render(
      <MaterialRenderer
        material={{ kind: "markdown", body: "[恶意](javascript:alert(1)) [正常](https://example.com)\n![图](https://example.com/a.png)\n![非 https](http://example.com/b.png)" }}
      />,
    );
    const el = screen.getByTestId("course-material-markdown");
    expect(el.querySelector('a[href^="javascript"]')).toBeNull();
    expect(el.innerHTML).not.toContain("javascript:");
    expect(el.querySelector('a[href="https://example.com"]')).not.toBeNull();
    // 图片不直连第三方，降级为指向原图的 https 外链
    expect(el.querySelector("img")).toBeNull();
    expect(el.querySelector('a[href="https://example.com/a.png"]')).not.toBeNull();
    expect(el.querySelector('a[href^="http://"]')).toBeNull();
  });

  it("keeps markdown typography safe from reader context rules (#1118)", () => {
    // 讲义挂在 .learning-reader__chapter / __issue / __objective 内。这三处的元素规则
    // 原先用后代选择器（.learning-reader__issue h3 等，(0,1,1)）且声明在讲义块之后，
    // 于是把讲义自己的排版盖掉（实测：讲义 h3 吃 19px/540 的单元标题样式、目标卡正文
    // 压成 13px 灰字）。根因修法是把它们收成**子选择器**（目标元素都是直接子节点），
    // 不再匹配嵌在 .learning-material 里的标题/段落——而非让讲义做特异性军备竞赛
    // （提权会反过来压掉本块 :first-child 的边距复位）。
    // happy-dom 不解终值，故按源断言这两条不变量；修法被回退即在此红。
    const css = readFileSync(resolve(import.meta.dirname, "../../app/globals.css"), "utf8");
    // 去掉注释：注释里会讨论这些选择器，不能当规则命中
    const rules = css.replace(/\/\*[\s\S]*?\*\//g, "");

    for (const ctx of [".learning-reader__chapter", ".learning-reader__issue", ".learning-reader__objective"]) {
      for (const el of ["h2", "h3", "h4", "p"]) {
        const descendant = new RegExp(`(^|[\\s,])${ctx.replace(/[.]/g, "\\.")} ${el}\\s*[,{]`, "m");
        expect(
          descendant.test(rules),
          `${ctx} ${el} 必须是子选择器（>），否则会盖掉 .learning-material 内的 ${el}`,
        ).toBe(false);
      }
    }
    expect(rules).toMatch(/\.learning-reader__chapter > h2\s*\{/);
    expect(rules).toMatch(/\.learning-reader__issue > h3\s*\{/);
    expect(rules).toMatch(/\.learning-reader__objective > p\s*\{/);
  });

  it("keeps footnote anchors resolvable and fragment links in-page (#1118)", () => {
    // rehype-sanitize 默认 clobberPrefix 会给 id 二次加前缀，而脚注 href 已带一层
    // → id 变 user-content-user-content-fn-a、href 仍是 #user-content-fn-a，跳转是死链。
    // 另：a 覆写若一律 target=_blank，点脚注会在新标签页打开同一页。
    render(
      <MaterialRenderer
        material={{ kind: "markdown", body: "脚注[^a]\n\n[^a]: 正文\n\n[跳](#sec)\n\n[外](https://example.com)\n\n[坏](javascript:alert(1))" }}
      />,
    );
    const el = screen.getByTestId("course-material-markdown");
    const item = el.querySelector("li[id]")!;
    const ref = el.querySelector('a[href^="#user-content-fn"]')!;
    expect(item.id).toBe("user-content-fn-a");
    expect(ref.getAttribute("href")).toBe("#" + item.id);
    expect(el.innerHTML).not.toContain("user-content-user-content");
    // 同页片段不新窗口；外链仍新窗口
    expect(el.querySelector('a[href="#sec"]')).not.toHaveAttribute("target");
    expect(el.querySelector('a[href="https://example.com"]')).toHaveAttribute("target", "_blank");
    // 危险协议不留空 href（空 href 会以新窗口打开当前页）——退化为纯文本
    expect(el.querySelector('a[href=""]')).toBeNull();
    expect(el.innerHTML).not.toContain("javascript:");
  });

  it("requires alt text and rejects unsafe image URLs", () => {
    render(<MaterialRenderer material={{ kind: "image", title: "图", url: "javascript:alert(1)" }} />);
    expect(screen.getByTestId("course-material-unavailable")).toHaveTextContent("图片材料缺少");
  });

  it("validates Bilibili IDs and falls back to an external link", () => {
    render(<MaterialRenderer material={{ kind: "video", title: "视频", provider: "unknown", external_id: "x", url: "https://example.com/video" }} />);
    expect(screen.getByTestId("course-material-link")).toHaveAttribute("href", "https://example.com/video");
  });

  it("video click-to-play gate: cover button first, iframe mounts after click", () => {
    render(<MaterialRenderer material={{ kind: "video", title: "讲解视频", provider: "bilibili", external_id: "BV1xx411c7mD", url: "https://www.bilibili.com/video/BV1xx411c7mD" }} />);
    const container = screen.getByTestId("course-material-video");
    // 初始无 iframe：封面按钮（播放文案 + 标题）+ 常驻 B 站原链接
    expect(container.querySelector("iframe")).toBeNull();
    const play = screen.getByTestId("course-material-video-play");
    expect(play).toHaveTextContent("播放视频");
    expect(play).toHaveTextContent("讲解视频");
    expect(container.querySelector('a[href="https://www.bilibili.com/video/BV1xx411c7mD"]')).not.toBeNull();

    fireEvent.click(play);
    const iframe = container.querySelector("iframe");
    expect(iframe).not.toBeNull();
    expect(iframe!.getAttribute("src")).toBe("https://player.bilibili.com/player.html?bvid=BV1xx411c7mD&page=1&autoplay=1");
    expect(iframe!.getAttribute("sandbox")).toBe("allow-scripts allow-same-origin allow-presentation");
    expect(iframe!.getAttribute("loading")).toBe("lazy");
    expect(iframe!.getAttribute("referrerpolicy")).toBe("no-referrer");
    // 点击后原链接仍常驻
    expect(container.querySelector('a[href="https://www.bilibili.com/video/BV1xx411c7mD"]')).not.toBeNull();
  });

  it("autoPlay mounts the iframe immediately without the cover button", () => {
    render(<MaterialRenderer material={{ kind: "video", title: "讲解视频", provider: "bilibili", external_id: "BV1xx411c7mD" }} autoPlay />);
    const container = screen.getByTestId("course-material-video");
    const iframe = container.querySelector("iframe");
    expect(iframe).not.toBeNull();
    expect(iframe!.getAttribute("src")).toBe("https://player.bilibili.com/player.html?bvid=BV1xx411c7mD&page=1&autoplay=1");
    expect(iframe!.getAttribute("allow")).toContain("autoplay");
    expect(screen.queryByTestId("course-material-video-play")).toBeNull();
  });

  it("video: bad BV id degrades to unavailable hint", () => {
    render(<MaterialRenderer material={{ kind: "video", title: "视频", provider: "bilibili", external_id: "not-a-bv" }} />);
    expect(screen.getByTestId("course-material-unavailable")).toBeInTheDocument();
    expect(screen.queryByTestId("course-material-video")).not.toBeInTheDocument();
  });

  it("shows a local image loading and failure state", () => {
    render(<MaterialRenderer material={{ kind: "image", title: "图", url: "https://example.com/a.png", alt_text: "图" }} />);
    expect(screen.getByTestId("course-material-image-loading")).toBeInTheDocument();
    fireEvent.error(screen.getByTestId("course-material-image").querySelector("img")!);
    expect(screen.getByTestId("course-material-image-error")).toBeInTheDocument();
  });
});
