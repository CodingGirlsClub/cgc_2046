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

  it("keeps markdown typography under reader context rules (#1118)", () => {
    // 讲义挂在 .learning-reader__chapter / __issue / __objective 里，而这些上下文规则
    // （.learning-reader__issue h3、.learning-reader__objective p，同为 0-1-1）声明在
    // 讲义样式之后。happy-dom 不解终值，故按源断言：**任何** 单类
    // `.learning-material--markdown` 选择器都不许出现——必须写成双类
    // （`.learning-material.learning-material--markdown`）把特异性提到 0-2-0，
    // 否则讲义 h3 会被渲染成 19px/540 的单元标题、目标卡正文被压成 13px 灰字。
    // 这条不变量与源码顺序无关，新增单类规则即在此红。
    const css = readFileSync(resolve(import.meta.dirname, "../../app/globals.css"), "utf8");
    const singleClass = [...css.matchAll(/(^|[^\w.-])\.learning-material--markdown(?![-\w])/g)].map(
      (match) => css.slice(match.index, match.index + 80).split("\n")[0],
    );
    expect(singleClass, "单类 .learning-material--markdown 会被阅读器上下文规则盖掉").toEqual([]);
    // 守卫成立的前提：上下文规则确实存在且声明在讲义块之后
    const markdownBlockAt = css.indexOf(".learning-material.learning-material--markdown");
    for (const ctx of [".learning-reader__issue h3 {", ".learning-reader__objective p {"]) {
      const at = css.indexOf(ctx);
      expect(at, `${ctx} 应存在于 globals.css`).toBeGreaterThan(-1);
      expect(at, `${ctx} 声明于讲义块之后，故讲义必须靠特异性取胜`).toBeGreaterThan(markdownBlockAt);
    }
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
