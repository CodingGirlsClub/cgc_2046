import { describe, it, expect, afterEach } from "vitest";
import { cleanup, screen, within } from "@testing-library/react";
import { render } from "@/test-utils";
import OnboardingConnectCard from "./onboarding-connect-card";

afterEach(cleanup);

describe("常驻接入卡 OnboardingConnectCard（plan first-mile-onboarding U3，R8）", () => {
	it("邀请态（hasActiveToken=false）：标题/说明 + 主 CTA 跳区入口页", () => {
		render(
			<OnboardingConnectCard slug="cgc-academy" hasActiveToken={false} />,
		);

		const card = screen.getByTestId("onboarding-connect-card");
		expect(card).toHaveAttribute("data-variant", "invite");
		expect(card).toHaveTextContent("接入你的 Agent");
		// CTA 同模态主 CTA：跳 /w/:slug/settings/integrations/agents
		const cta = within(card).getByTestId("onboarding-connect-card-cta");
		expect(cta).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents",
		);
		expect(cta).toHaveTextContent("开始接入");
	});

	it("等待首联态（hasActiveToken=true，AE5 前半）：提醒文案 + 指引链接，无主 CTA 文案", () => {
		render(<OnboardingConnectCard slug="cgc-academy" hasActiveToken />);

		const card = screen.getByTestId("onboarding-connect-card");
		expect(card).toHaveAttribute("data-variant", "waiting");
		expect(card).toHaveTextContent("等待你的 Agent 第一次连接");
		expect(card).not.toHaveTextContent("开始接入");
		const cta = within(card).getByTestId("onboarding-connect-card-cta");
		expect(cta).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents",
		);
	});
});
