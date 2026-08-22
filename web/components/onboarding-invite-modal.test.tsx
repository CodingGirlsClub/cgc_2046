import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { act, cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { render } from "@/test-utils";
import OnboardingInviteModal from "./onboarding-invite-modal";

const { dismissOnboardingInvitation } = vi.hoisted(() => ({
	dismissOnboardingInvitation: vi.fn(),
}));

vi.mock("@/lib/onboarding", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, dismissOnboardingInvitation };
});

beforeEach(() => {
	vi.clearAllMocks();
	dismissOnboardingInvitation.mockResolvedValue(undefined);
});

afterEach(cleanup);

describe("首公里邀请模态 OnboardingInviteModal（plan first-mile-onboarding U3，R1/R2）", () => {
	it("开框：role=dialog + 标题/价值说明/三动作，焦点落在对话框本体", () => {
		render(<OnboardingInviteModal slug="cgc-academy" onClose={() => {}} />);

		const dialog = screen.getByRole("dialog");
		expect(dialog).toHaveAttribute("aria-modal", "true");
		// 宽变体：三动作行在默认 420px 下溢出（按钮探出框体）
		expect(dialog).toHaveClass("modal-content--wide");
		expect(dialog).toHaveTextContent("把你的 Agent 接入 2046");
		expect(dialog).toHaveTextContent(/学课程、查活动、参与协作/);
		expect(
			screen.getByRole("link", { name: "开始接入" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("button", { name: "再看看" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("button", { name: "暂时不用，别再弹了" }),
		).toBeInTheDocument();
		// 开框聚焦对话框本体（Esc/Tab trap 的焦点锚点）
		expect(document.activeElement).toBe(dialog);
	});

	it("「开始接入」→ /w/:slug/settings/integrations/agents（同常驻卡 CTA 目标），并关框防 back 导航重弹（KTD4）", () => {
		const onClose = vi.fn();
		render(<OnboardingInviteModal slug="cgc-academy" onClose={onClose} />);

		const cta = screen.getByTestId("onboarding-invite-start");
		expect(cta).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents",
		);
		fireEvent.click(cta);
		expect(onClose).toHaveBeenCalledTimes(1);
	});

	it("「再看看」/ Esc / ✕ / 点遮罩：均只关闭（F3：下次登录再弹），内容区点击不关", () => {
		const onClose = vi.fn();
		render(<OnboardingInviteModal slug="cgc-academy" onClose={onClose} />);

		fireEvent.click(screen.getByRole("button", { name: "再看看" }));
		expect(onClose).toHaveBeenCalledTimes(1);

		fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
		expect(onClose).toHaveBeenCalledTimes(2);

		fireEvent.click(screen.getByTestId("onboarding-invite-close"));
		expect(onClose).toHaveBeenCalledTimes(3);

		// 遮罩点击 = 再看看；内容区点击不冒泡关框
		fireEvent.click(screen.getByTestId("onboarding-invite-overlay"));
		expect(onClose).toHaveBeenCalledTimes(4);
		fireEvent.click(screen.getByRole("dialog"));
		expect(onClose).toHaveBeenCalledTimes(4);
	});

	it("「暂时不用，别再弹了」成功：调 dismissOnboardingInvitation 后关闭（AE2 后半，服务端持久拒绝）", async () => {
		const onClose = vi.fn();
		render(<OnboardingInviteModal slug="cgc-academy" onClose={onClose} />);

		fireEvent.click(screen.getByTestId("onboarding-invite-dismiss"));

		await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
		expect(dismissOnboardingInvitation).toHaveBeenCalledTimes(1);
	});

	it("拒绝失败：不关框 + 内联 role=alert，按钮可重试（AE2）", async () => {
		dismissOnboardingInvitation.mockRejectedValue(new Error("boom"));
		const onClose = vi.fn();
		render(<OnboardingInviteModal slug="cgc-academy" onClose={onClose} />);

		fireEvent.click(screen.getByTestId("onboarding-invite-dismiss"));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"操作失败，请稍后重试。",
		);
		expect(onClose).not.toHaveBeenCalled();
		expect(screen.getByRole("dialog")).toBeInTheDocument();
		expect(screen.getByTestId("onboarding-invite-dismiss")).toBeEnabled();
	});

	it("dismiss 在飞时 Esc/遮罩/✕ 不关框；拒绝落地后内联 role=alert（busy-gated close，AE2）", async () => {
		const dismiss = Promise.withResolvers<void>();
		dismissOnboardingInvitation.mockImplementation(() => dismiss.promise);

		// 壳组件由 onClose 真实卸载：验证 busy 闸门挡住「关框 = 卸载」的竞态
		function Harness() {
			const [open, setOpen] = useState(true);
			return open ? (
				<OnboardingInviteModal slug="cgc-academy" onClose={() => setOpen(false)} />
			) : null;
		}
		render(<Harness />);

		fireEvent.click(screen.getByTestId("onboarding-invite-dismiss"));
		expect(screen.getByTestId("onboarding-invite-dismiss")).toBeDisabled();

		// busy 在飞：Esc / 遮罩 / ✕ / 再看看 均不得关框
		fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
		fireEvent.click(screen.getByTestId("onboarding-invite-overlay"));
		fireEvent.click(screen.getByTestId("onboarding-invite-close"));
		fireEvent.click(screen.getByTestId("onboarding-invite-later"));
		expect(screen.getByRole("dialog")).toBeInTheDocument();

		// 拒绝落地：框仍在，内联错误不被卸载吞掉
		await act(async () => {
			dismiss.reject(new Error("boom"));
		});
		expect(await screen.findByRole("alert")).toHaveTextContent(
			"操作失败，请稍后重试。",
		);
		expect(screen.getByRole("dialog")).toBeInTheDocument();
	});

	it("dismiss 在飞时主 CTA 不关框也不导航；拒绝落地后仍显示内联错误（AE2）", async () => {
		const dismiss = Promise.withResolvers<void>();
		dismissOnboardingInvitation.mockImplementation(() => dismiss.promise);

		function Harness() {
			const [open, setOpen] = useState(true);
			return open ? (
				<OnboardingInviteModal slug="cgc-academy" onClose={() => setOpen(false)} />
			) : null;
		}
		render(<Harness />);

		fireEvent.click(screen.getByTestId("onboarding-invite-dismiss"));
		const cta = screen.getByTestId("onboarding-invite-start");
		fireEvent.click(cta);

		expect(screen.getByRole("dialog")).toBeInTheDocument();
		expect(cta).toHaveAttribute("aria-disabled", "true");

		await act(async () => {
			dismiss.reject(new Error("boom"));
		});
		expect(await screen.findByRole("alert")).toHaveTextContent(
			"操作失败，请稍后重试。",
		);
	});

	it("Tab focus trap：末位 Tab 回首位，首位 Shift+Tab 回末位", () => {
		render(<OnboardingInviteModal slug="cgc-academy" onClose={() => {}} />);

		const dialog = screen.getByRole("dialog");
		const first = screen.getByTestId("onboarding-invite-close");
		const last = screen.getByTestId("onboarding-invite-start");

		last.focus();
		fireEvent.keyDown(dialog, { key: "Tab" });
		expect(document.activeElement).toBe(first);

		first.focus();
		fireEvent.keyDown(dialog, { key: "Tab", shiftKey: true });
		expect(document.activeElement).toBe(last);
	});
});
