import { render } from "@/test-utils";
import { fireEvent, screen } from "@testing-library/react";
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
    expect(iframe!.getAttribute("src")).toBe("https://player.bilibili.com/player.html?bvid=BV1xx411c7mD&page=1");
    expect(iframe!.getAttribute("sandbox")).toBe("allow-scripts allow-same-origin allow-presentation");
    expect(iframe!.getAttribute("loading")).toBe("lazy");
    expect(iframe!.getAttribute("referrerpolicy")).toBe("no-referrer");
    // 点击后原链接仍常驻
    expect(container.querySelector('a[href="https://www.bilibili.com/video/BV1xx411c7mD"]')).not.toBeNull();
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
