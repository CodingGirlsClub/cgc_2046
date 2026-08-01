import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, cleanup, waitFor } from "@testing-library/react";
import WorkspacePage from "./page";
import { MOCK_WORKSPACES } from "@/lib/workspaces";

const { push, replace } = vi.hoisted(() => ({ push: vi.fn(), replace: vi.fn() }));
const { isAuthenticated } = vi.hoisted(() => ({ isAuthenticated: vi.fn() }));
const { params } = vi.hoisted(() => ({ params: { value: { slug: "cgc-academy" } } }));

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push, replace }),
  useParams: () => params.value,
}));

vi.mock("@/lib/auth", () => ({
  isAuthenticated,
  clearAuthToken: vi.fn(),
}));

beforeEach(() => {
  vi.clearAllMocks();
  isAuthenticated.mockReturnValue(true);
  params.value = { slug: "cgc-academy" };
});

afterEach(cleanup);

describe("工作区占位页 /w/[slug] (#63)", () => {
  it("未登录：重定向 /login", async () => {
    isAuthenticated.mockReturnValue(false);
    render(<WorkspacePage />);
    await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
  });

  it("按 slug 匹配 mock：展示名称/slug/加入方式/赞助入口", async () => {
    render(<WorkspacePage />);
    expect(await screen.findByText("CGC 线上学院")).toBeInTheDocument();
    expect(screen.getByText("cgc-academy")).toBeInTheDocument();
    expect(screen.getByText("申请审批")).toBeInTheDocument();
    expect(screen.getByText("已开启")).toBeInTheDocument();
  });

  it("未知 slug：展示建设中占位", async () => {
    params.value = { slug: "not-exist" };
    render(<WorkspacePage />);
    expect(await screen.findByText(/建设中/)).toBeInTheDocument();
    expect(MOCK_WORKSPACES.length).toBeGreaterThan(0); // 引用 mock 防 tree-shake
  });

  it("提供返回工作台链接", async () => {
    render(<WorkspacePage />);
    const back = await screen.findByRole("link", { name: /← 工作台/ });
    expect(back).toHaveAttribute("href", "/");
  });
});
