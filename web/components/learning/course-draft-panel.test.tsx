import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import CourseDraftPanel from "@/components/learning/course-draft-panel";
import { COURSE_DRAFT } from "@/lib/graphql/course-content";

const { useQuery } = vi.hoisted(() => ({ useQuery: vi.fn() }));
vi.mock("@apollo/client/react", () => ({ useQuery }));

const DRAFT_CONTENT = JSON.stringify({
  goals: ["能讲懂代码"],
  chapters: [{ id: "ch-1", title: "入门" }],
  issues: [
    {
      id: "iss-1",
      kind: "thoughtwork",
      title: "读懂循环",
      chapter_id: "ch-1",
      story: { goal: "理解循环结构" },
      objectives: [{ id: "obj-1", title: "写出 for 循环" }],
    },
  ],
});

const DRAFT = {
  courseId: "course-1",
  title: "Python 入门",
  version: 3,
  prepState: "authoring",
  updatedAt: "2026-09-01T10:00:00Z",
  content: DRAFT_CONTENT,
};

function mockCourseDraft(courseDraft: unknown) {
  useQuery.mockImplementation((doc: unknown) => {
    if (doc === COURSE_DRAFT) {
      return { data: { courseDraft }, loading: false, error: null };
    }
    return { data: undefined, loading: false, error: null };
  });
}

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

describe("CourseDraftPanel（H6 教研 draft 预览）", () => {
  it("draft 存在：渲染版本号/更新时间/prepState 徽标 + 草稿内容（复用 viewer 渲染主体）", () => {
    mockCourseDraft(DRAFT);
    render(<CourseDraftPanel courseId="course-1" />);

    expect(screen.getByTestId("course-draft-panel")).toBeTruthy();
    expect(screen.getByTestId("course-draft-state").textContent).toBe("撰写中");
    const meta = screen.getByTestId("course-draft-meta").textContent;
    expect(meta).toContain("3");
    expect(meta).toContain("2026");
    // draft 内容经共享渲染主体输出（章节/单元/kind 翻译）
    expect(screen.getByText("入门")).toBeTruthy();
    expect(screen.getByText("读懂循环")).toBeTruthy();
    expect(screen.getByText(/思考型/)).toBeTruthy();
    expect(screen.getByText("写出 for 循环")).toBeTruthy();
  });

  it("courseDraft 为 null（无权/课程不存在）：不渲染区块", () => {
    mockCourseDraft(null);
    const { container } = render(<CourseDraftPanel courseId="course-1" />);
    expect(container.firstChild).toBeNull();
    expect(screen.queryByTestId("course-draft-panel")).toBeNull();
  });

  it("有权但尚无草稿（version=null）：不渲染区块", () => {
    mockCourseDraft({ ...DRAFT, version: null, prepState: null, updatedAt: null, content: null });
    const { container } = render(<CourseDraftPanel courseId="course-1" />);
    expect(container.firstChild).toBeNull();
  });

  it("未知 prepState 回退原串徽标", () => {
    mockCourseDraft({ ...DRAFT, prepState: "custom_state" });
    render(<CourseDraftPanel courseId="course-1" />);
    expect(screen.getByTestId("course-draft-state").textContent).toBe("custom_state");
  });

  it("loading 中不渲染（避免闪现后布局跳动）", () => {
    useQuery.mockImplementation(() => ({ data: undefined, loading: true, error: null }));
    const { container } = render(<CourseDraftPanel courseId="course-1" />);
    expect(container.firstChild).toBeNull();
  });
});
