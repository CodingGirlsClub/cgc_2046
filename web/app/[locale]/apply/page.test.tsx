import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import ApplyPage from "./page";

const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { createApplication, fetchMyApplications } = vi.hoisted(() => ({
	createApplication: vi.fn(),
	fetchMyApplications: vi.fn(),
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@/lib/admin", () => ({ createApplication, fetchMyApplications }));

// 套 SitePage 顶导后引入语言切换器（next-intl useRouter 依赖 app router）：
// mock 掉，表单行为不受影响
vi.mock("@/components/language-switcher", () => ({
	default: () => null,
}));

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
	fetchMyApplications.mockResolvedValue([]);
});

afterEach(cleanup);

describe("/apply 申请创建工作台", () => {
	it("渲染表单（name/slug/purpose）", () => {
		render(<ApplyPage />);

		expect(screen.getByRole("heading", { name: /申请创建工作台/ })).toBeInTheDocument();
		expect(screen.getByPlaceholderText(/名称/)).toBeInTheDocument();
		expect(screen.getByPlaceholderText(/slug/)).toBeInTheDocument();
		expect(screen.getByPlaceholderText(/用途/)).toBeInTheDocument();
	});

	it("提交表单调用 createApplication 并显示成功/待审批状态", async () => {
		createApplication.mockResolvedValue({
			result: {
				id: "app1",
				applicantId: "u1",
				name: "研究空间",
				slug: "research",
				purpose: "团队研究",
				status: "pending",
				rejectionReason: null,
				insertedAt: "2026-08-01T00:00:00Z",
			},
			errors: [],
		});

		render(<ApplyPage />);

		fireEvent.change(screen.getByPlaceholderText(/名称/), {
			target: { value: "研究空间" },
		});
		fireEvent.change(screen.getByPlaceholderText(/slug/), {
			target: { value: "research" },
		});
		fireEvent.change(screen.getByPlaceholderText(/用途/), {
			target: { value: "团队研究" },
		});
		fireEvent.click(screen.getByRole("button", { name: /提交/ }));

		await vi.waitFor(() =>
			expect(createApplication).toHaveBeenCalledWith({
				name: "研究空间",
				slug: "research",
				purpose: "团队研究",
				applicantId: "u1",
			}),
		);
		expect(await screen.findByText(/提交成功|待审批/)).toBeInTheDocument();
	});

	it("提交失败展示错误消息", async () => {
		createApplication.mockResolvedValue({
			result: null,
			errors: [{ message: "slug 已被占用", code: "invalid_attribute" }],
		});

		render(<ApplyPage />);

		fireEvent.change(screen.getByPlaceholderText(/名称/), {
			target: { value: "研究空间" },
		});
		fireEvent.change(screen.getByPlaceholderText(/slug/), {
			target: { value: "taken" },
		});
		fireEvent.change(screen.getByPlaceholderText(/用途/), {
			target: { value: "团队研究" },
		});
		fireEvent.click(screen.getByRole("button", { name: /提交/ }));

		expect(await screen.findByText(/slug 已被占用/)).toBeInTheDocument();
	});

	it("未登录时提示登录", () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true, userId: null });

		render(<ApplyPage />);

		// 顶导（SiteHeader）与正文各有「登录」链接（顶导的 → 是 aria-hidden，
		// 两者可访问名相同）：断言两处都在，且表单不渲染。
		expect(screen.getAllByRole("link", { name: "登录" })).toHaveLength(2);
		expect(screen.queryByPlaceholderText(/名称/)).not.toBeInTheDocument();
	});

	it("我的申请列表渲染（R7a：申请人看自己的申请状态）", async () => {
		createApplication.mockResolvedValue({
			result: {
				id: "app1",
				applicantId: "u1",
				name: "研究空间",
				slug: "research",
				purpose: "团队研究",
				status: "pending",
				rejectionReason: null,
				insertedAt: "2026-08-01T00:00:00Z",
			},
			errors: [],
		});
		fetchMyApplications.mockResolvedValue([
			{
				id: "app1",
				applicantId: "u1",
				name: "研究空间",
				slug: "research",
				purpose: "团队研究",
				status: "pending",
				rejectionReason: null,
				insertedAt: "2026-08-01T00:00:00Z",
			},
		]);

		render(<ApplyPage />);

		// 挂载时首次加载我的申请，列表出现状态徽章（l-badge 中的"待审批"）
		expect(await screen.findAllByText("待审批")).not.toHaveLength(0);
		expect(fetchMyApplications).toHaveBeenCalledTimes(1);

		fireEvent.change(screen.getByPlaceholderText(/名称/), {
			target: { value: "研究空间" },
		});
		fireEvent.change(screen.getByPlaceholderText(/slug/), {
			target: { value: "research" },
		});
		fireEvent.change(screen.getByPlaceholderText(/用途/), {
			target: { value: "团队研究" },
		});
		fireEvent.click(screen.getByRole("button", { name: /提交/ }));

		// #205：提交成功后 loadMyApps 必须重新调用 fetchMyApplications（刷新列表），而非依赖缓存
		await vi.waitFor(() => expect(fetchMyApplications).toHaveBeenCalledTimes(2));
		expect(screen.getAllByText("待审批").length).toBeGreaterThan(0);
	});
});
